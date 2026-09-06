import { createClient } from '../../stockGame_admin_react/node_modules/@supabase/supabase-js/dist/index.mjs';

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:54321';
const ANON_KEY = process.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

console.log('================================================================');
console.log('🔄 Phase 4 Part 2: Classroom 1-Click Session Reset Automated TDD');
console.log('Target:', SUPABASE_URL);
console.log('================================================================\n');

async function runTests() {
    let passed = 0;
    let total = 0;

    function assert(desc, condition, detail = '') {
        total++;
        if (condition) {
            passed++;
            console.log(`✅ [PASS] ${desc} ${detail ? `(${detail})` : ''}`);
        } else {
            console.error(`❌ [FAIL] ${desc} ${detail ? `(${detail})` : ''}`);
        }
    }

    const adminServiceClient = createClient(SUPABASE_URL, SERVICE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false }
    });

    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
        auth: { persistSession: false }
    });

    try {
        // -------------------------------------------------------------
        // 사전 준비: 관리자 로그인 및 테스트용 학생/주식 데이터 세팅
        // -------------------------------------------------------------
        const { data: adminAuth } = await userClient.auth.signInWithPassword({
            email: 'admin@stockgame.local',
            password: '1234'
        });
        const authenticatedAdminClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: { headers: { Authorization: `Bearer ${adminAuth.session.access_token}` } }
        });

        // 테스트용 학생 계정 2명 생성
        const stuEmail1 = `reset_stu1_${Date.now()}@stockgame.local`;
        const { data: stu1Created } = await adminServiceClient.auth.admin.createUser({
            email: stuEmail1,
            password: 'password123',
            email_confirm: true,
            user_metadata: { student_id: `rst1_${Date.now()}`, name: '리셋테스트학생1', role: 'ROLE_STUDENT' }
        });
        const stuId1 = stu1Created.user.id;

        const stuEmail2 = `reset_stu2_${Date.now()}@stockgame.local`;
        const { data: stu2Created } = await adminServiceClient.auth.admin.createUser({
            email: stuEmail2,
            password: 'password123',
            email_confirm: true,
            user_metadata: { student_id: `rst2_${Date.now()}`, name: '리셋테스트학생2', role: 'ROLE_STUDENT' }
        });
        const stuId2 = stu2Created.user.id;

        // 학생 1: 포인트 50,000P 및 주식 10주 보유 상태 조작
        await adminServiceClient.from('profiles').update({ total_point: 50000 }).eq('id', stuId1);
        
        const { data: anyStock } = await userClient.from('stocks').select('*').eq('status', 'LISTED').limit(1).single();
        assert('테스트 종목 확보', !!anyStock?.id, `종목: ${anyStock?.name}`);

        await adminServiceClient.from('user_holdings').insert({
            user_id: stuId1,
            stock_id: anyStock.id,
            amount: 10,
            locked_amount: 0,
            average_price: 1500,
            total_invested_amount: 15000
        });

        // 학생 2: 미체결 매수 주문(PENDING) 1건 등록 (임의 주문 삽입)
        const { data: dummyOrder, error: orderInsertErr } = await adminServiceClient.from('orders').insert({
            user_id: stuId2,
            stock_id: anyStock.id,
            order_type: 'BUY',
            price: 800,
            amount: 5,
            remain_amount: 5,
            status: 'PENDING'
        }).select().single();

        assert('테스트용 미체결 주문 등록 성공', !orderInsertErr && !!dummyOrder?.id);

        // 종목 현재가를 의도적으로 변동시킴 (예: 9999원으로 왜곡)
        await adminServiceClient.from('stocks').update({ current_price: 9999 }).eq('id', anyStock.id);

        // -------------------------------------------------------------
        // TC R.1: 관리자 권한으로 교실 세션 1-클릭 리셋 RPC 호출
        // -------------------------------------------------------------
        console.log('\n--- [TC R.1] 교실 세션 1-클릭 리셋 RPC (admin_reset_classroom_session) 호출 ---');
        const { data: resetRes, error: resetErr } = await authenticatedAdminClient.rpc('admin_reset_classroom_session', {
            p_default_point: 100000,
            p_reset_stock_price: true
        });

        assert('세션 1-클릭 리셋 RPC 호출 성공', !resetErr && resetRes?.success === true, resetErr?.message);
        assert('리셋 응답 필드 확인 (학생, 주문, 주식 리셋 카운트 포함)', resetRes?.resetStudentsCount >= 2 && resetRes?.cancelledOrdersCount >= 1);

        // -------------------------------------------------------------
        // TC R.2: 학생 포인트 100,000P 일괄 원복 및 보유 주식 0주 청산 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC R.2] 학생 포인트 100,000P 원복 및 보유주식 0주 청산 검증 ---');
        const { data: p1After } = await adminServiceClient.from('profiles').select('total_point').eq('id', stuId1).single();
        const { data: p2After } = await adminServiceClient.from('profiles').select('total_point').eq('id', stuId2).single();

        assert('학생1 포인트 100,000P 초기화 확인', p1After?.total_point === 100000, `Point: ${p1After?.total_point}`);
        assert('학생2 포인트 100,000P 초기화 확인', p2After?.total_point === 100000, `Point: ${p2After?.total_point}`);

        const { data: holdingAfter } = await adminServiceClient.from('user_holdings').select('amount').eq('user_id', stuId1).eq('stock_id', anyStock.id).single();
        assert('학생1 보유 주식 잔고 0주 초기화 확인', holdingAfter?.amount === 0, `Amount: ${holdingAfter?.amount}`);

        // -------------------------------------------------------------
        // TC R.3: 미체결 주문 일괄 취소(CANCELLED) 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC R.3] 미체결 주문 일괄 취소(CANCELLED) 검증 ---');
        const { data: orderAfter } = await adminServiceClient.from('orders').select('status, remain_amount').eq('id', dummyOrder.id).single();
        assert('미체결 주문 CANCELLED 상태 전이 확인', orderAfter?.status === 'CANCELLED' && orderAfter?.remain_amount === 0);

        // -------------------------------------------------------------
        // TC R.4: 종목 시세 최초 발행가로 원복 및 상하한가 재계산 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC R.4] 종목 시세 최초 발행가로 원복 및 상하한가 재계산 검증 ---');
        const { data: stockAfter } = await userClient.from('stocks').select('current_price, publication_price, high_limit_price, low_limit_price').eq('id', anyStock.id).single();
        assert('종목 현재가 발행가로 원복 확인', stockAfter?.current_price === stockAfter?.publication_price, `Current: ${stockAfter?.current_price} === Pub: ${stockAfter?.publication_price}`);
        assert('상하한가 자동 재계산 일치 (±30%)', stockAfter?.high_limit_price === Math.round(stockAfter.publication_price * 1.3));

        // -------------------------------------------------------------
        // TC R.5: 일반 학생 계정의 리셋 RPC 호출 차단(RLS 보안 가드) 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC R.5] 학생 계정 리셋 RPC 호출 차단 가드 검증 ---');
        const { data: studentLogin } = await userClient.auth.signInWithPassword({
            email: stuEmail1,
            password: 'password123'
        });
        const studentClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: { headers: { Authorization: `Bearer ${studentLogin.session.access_token}` } }
        });

        const { error: studentUnauthorizedErr } = await studentClient.rpc('admin_reset_classroom_session', {
            p_default_point: 100000,
            p_reset_stock_price: true
        });

        assert('학생 권한으로 리셋 RPC 호출 시 차단 가드 동작 (예외 반환)', !!studentUnauthorizedErr && studentUnauthorizedErr.message.includes('관리자 권한'));

        // -------------------------------------------------------------
        // TC R.6: 세션 리셋 감사 이력(SESSION_RESET) 적재 확인
        // -------------------------------------------------------------
        console.log('\n--- [TC R.6] 세션 리셋 감사 로그(point_transactions) 적재 확인 ---');
        const { data: resetLogs } = await authenticatedAdminClient.from('point_transactions').select('*').eq('user_id', stuId1).eq('reason_type', 'SESSION_RESET');
        assert('SESSION_RESET 감사 이력 적재 확인', resetLogs && resetLogs.length >= 1);

        // 클린업: 테스트 계정 삭제
        await adminServiceClient.rpc('admin_delete_student', { p_user_id: stuId1 });
        await adminServiceClient.rpc('admin_delete_student', { p_user_id: stuId2 });

    } catch (globalErr) {
        console.error('Test execution error:', globalErr);
    }

    console.log('\n================================================================');
    console.log(`Phase 4 Part 2 Classroom Reset Test Summary: ${passed} / ${total} PASS`);
    console.log('================================================================');

    if (passed === total && total > 0) {
        process.exit(0);
    } else {
        process.exit(1);
    }
}

runTests();
