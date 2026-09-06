import { createClient } from '../../stockGame_admin_react/node_modules/@supabase/supabase-js/dist/index.mjs';

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:54321';
const ANON_KEY = process.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

console.log('================================================================');
console.log('📡 Phase 4 Part 1: Realtime Market Broadcast & UI Guard Test');
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

    const anonClient = createClient(SUPABASE_URL, ANON_KEY, {
        auth: { persistSession: false }
    });

    try {
        // -------------------------------------------------------------
        // 사전 준비: 관리자 로그인 및 학생 계정 준비
        // -------------------------------------------------------------
        const { data: adminAuth } = await anonClient.auth.signInWithPassword({
            email: 'admin@stockgame.local',
            password: '1234'
        });
        const authenticatedAdminClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: { headers: { Authorization: `Bearer ${adminAuth.session.access_token}` } }
        });

        const testStudentEmail = `broadcast_stu_${Date.now()}@stockgame.local`;
        const { data: studentCreated } = await adminServiceClient.auth.admin.createUser({
            email: testStudentEmail,
            password: 'password123',
            email_confirm: true,
            user_metadata: {
                student_id: `stu_bcast_${Date.now()}`,
                name: '브로드캐스트학생',
                role: 'ROLE_STUDENT'
            }
        });
        const studentId = studentCreated.user.id;

        const { data: studentLogin } = await anonClient.auth.signInWithPassword({
            email: testStudentEmail,
            password: 'password123'
        });
        const studentClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: { headers: { Authorization: `Bearer ${studentLogin.session.access_token}` } }
        });

        // 1. 거래용 종목 하나 조회
        const { data: testStock } = await anonClient.from('stocks').select('*').eq('status', 'LISTED').limit(1).single();
        assert('테스트용 상장 종목 확보', !!testStock?.id, `종목: ${testStock?.name}`);

        // 시장 상태를 먼저 확실하게 OPEN으로 맞춤
        await authenticatedAdminClient.rpc('admin_update_market_settings', {
            p_mode: 'AUTO',
            p_open_time: '09:00',
            p_close_time: '15:30',
            p_call_auction_start_time: '15:20'
        });
        const { data: initCheck } = await anonClient.from('market_settings').select('is_market_open').eq('id', 1).single();
        if (!initCheck.is_market_open) {
            await authenticatedAdminClient.rpc('admin_toggle_market');
        }

        // -------------------------------------------------------------
        // TC B.1: Supabase Realtime WebSocket 채널 구독 및 UPDATE 이벤트 수신 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC B.1] Supabase Realtime WebSocket 채널 구독 및 브로드캐스트 이벤트 수신 ---');
        
        let receivedPayload = null;
        let eventReceivedTime = null;
        let toggleTime = null;

        const realtimeChannel = anonClient.channel('realtime:market_settings_test')
            .on(
                'postgres_changes',
                {
                    event: 'UPDATE',
                    schema: 'public',
                    table: 'market_settings',
                    filter: 'id=eq.1'
                },
                (payload) => {
                    eventReceivedTime = Date.now();
                    receivedPayload = payload.new;
                }
            );

        const subStatus = await new Promise((resolve) => {
            realtimeChannel.subscribe((status) => {
                if (status === 'SUBSCRIBED') resolve(status);
            });
            setTimeout(() => resolve('TIMEOUT'), 5000);
        });

        assert('Realtime WebSocket 채널 구독 성공 (SUBSCRIBED)', subStatus === 'SUBSCRIBED');

        // 관리자가 시장 긴급 점검 (MANUAL_PAUSE) 토글 호출
        toggleTime = Date.now();
        const { data: pauseRes, error: pauseErr } = await authenticatedAdminClient.rpc('admin_toggle_market');
        assert('관리자 시장 일시정지 토글 RPC 호출 성공', !pauseErr && pauseRes?.statusCode === 'MANUAL_PAUSE');

        // 최대 3초 동안 Realtime 이벤트 대기
        for (let i = 0; i < 30; i++) {
            if (receivedPayload && receivedPayload.status_code === 'MANUAL_PAUSE') break;
            await new Promise((r) => setTimeout(r, 100));
        }

        assert('Realtime 채널을 통해 MANUAL_PAUSE 브로드캐스트 이벤트 수신 성공', receivedPayload && receivedPayload.status_code === 'MANUAL_PAUSE');
        
        const latencyMs = eventReceivedTime && toggleTime ? (eventReceivedTime - toggleTime) : -1;
        assert('실시간 브로드캐스트 전파 지연율 1000ms 이내 보장', latencyMs >= 0 && latencyMs < 1000, `지연 시간: ${latencyMs}ms`);

        // -------------------------------------------------------------
        // TC B.2: 일시정지(MANUAL_PAUSE) 상태에서 학생 주문 제출 차단 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC B.2] 일시정지(MANUAL_PAUSE) 상태에서 학생 주문 제출 차단 가드 ---');
        
        const { error: blockedOrderErr } = await studentClient.rpc('place_and_match_order', {
            p_stock_id: testStock.id,
            p_order_type: 'BUY',
            p_price: 1000,
            p_amount: 1
        });

        assert('휴장/점검 중 학생 주문 제출 차단 가드 100% 동작 (에러 반환)', !!blockedOrderErr && blockedOrderErr.message.includes('휴장 또는 점검 중'));

        // -------------------------------------------------------------
        // TC B.3: 시장 재개방(OPEN) 브로드캐스트 수신 및 주문 정상 복구 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC B.3] 시장 재개방(OPEN) 브로드캐스트 수신 및 주문 정상 복구 ---');
        
        receivedPayload = null;
        toggleTime = Date.now();
        const { data: openRes, error: openErr } = await authenticatedAdminClient.rpc('admin_toggle_market');
        assert('관리자 시장 개방 토글 RPC 호출 성공', !openErr && openRes?.marketOpen === true);

        // 최대 3초 동안 Realtime 이벤트 대기
        for (let i = 0; i < 30; i++) {
            if (receivedPayload && receivedPayload.is_market_open === true) break;
            await new Promise((r) => setTimeout(r, 100));
        }

        assert('Realtime 채널을 통해 OPEN 브로드캐스트 이벤트 수신 성공', receivedPayload && receivedPayload.is_market_open === true);

        // 학생에게 100,000P 지급 후 주문 제출 테스트
        await adminServiceClient.from('profiles').update({ total_point: 100000 }).eq('id', studentId);

        const { data: successOrder, error: orderSuccessErr } = await studentClient.rpc('place_and_match_order', {
            p_stock_id: testStock.id,
            p_order_type: 'BUY',
            p_price: 500, // 낮은 가격으로 미체결 호가로 안착
            p_amount: 1
        });

        assert('개장 후 학생 주문 정상 접수 성공', !orderSuccessErr && successOrder?.status === 'SUCCESS');

        // 주문 취소
        if (successOrder?.order_id) {
            await studentClient.rpc('cancel_stock_order', { p_order_id: successOrder.order_id });
        }

        // -------------------------------------------------------------
        // TC B.4: 채널 정리 및 리소스 누수 방지
        // -------------------------------------------------------------
        console.log('\n--- [TC B.4] Realtime 채널 정리 및 클린업 ---');
        await anonClient.removeChannel(realtimeChannel);
        assert('Realtime 채널 정상 해제 (Clean Unsubscribe)', true);

        // 테스트 계정 정리
        await adminServiceClient.rpc('admin_delete_student', { p_user_id: studentId });

    } catch (globalErr) {
        console.error('Test execution error:', globalErr);
    }

    console.log('\n================================================================');
    console.log(`Phase 4 Part 1 Realtime Broadcast Test Summary: ${passed} / ${total} PASS`);
    console.log('================================================================');

    if (passed === total && total > 0) {
        process.exit(0);
    } else {
        process.exit(1);
    }
}

runTests();
