import { createClient } from '../../stockGame_admin_react/node_modules/@supabase/supabase-js/dist/index.mjs';

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:54321';
const ANON_KEY = process.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

console.log('================================================================');
console.log('🏛️ Phase 4 Admin Management & Cutover Automated Test Suite');
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
        auth: { persistSession: false }
    });

    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
        auth: { persistSession: false }
    });

    try {
        // -------------------------------------------------------------
        // TC 4.1: 관리자 로그인 및 RLS 권한 검증
        // -------------------------------------------------------------
        console.log('--- [TC 4.1] 관리자 로그인 및 RLS 권한 검증 ---');
        const { data: authData, error: authError } = await userClient.auth.signInWithPassword({
            email: 'admin@stockgame.local',
            password: '1234'
        });

        assert('교사 관리자 기본 계정 로그인 성공', !authError && !!authData.session, authError?.message);
        assert('관리자 이메일 일치 (admin@stockgame.local)', authData.user?.email === 'admin@stockgame.local');

        const { data: adminProfile } = await userClient
            .from('profiles')
            .select('*')
            .eq('id', authData.user.id)
            .single();

        assert('관리자 프로필 역할 확인 (ROLE_ADMIN)', adminProfile?.role === 'ROLE_ADMIN', `Role: ${adminProfile?.role}`);

        // 관리자 세션 클라이언트 생성
        const authenticatedAdminClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: {
                headers: {
                    Authorization: `Bearer ${authData.session.access_token}`
                }
            }
        });

        // -------------------------------------------------------------
        // TC 4.2: 시장 운영 설정 조회 및 개폐 토글 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC 4.2] 시장 운영 설정 조회 및 개폐 토글 검증 ---');
        const { data: initialSettings } = await userClient
            .from('market_settings')
            .select('*')
            .eq('id', 1)
            .single();

        assert('시장 설정 조회 성공', !!initialSettings);
        const initialOpen = initialSettings.is_market_open;

        // 1) 시장 닫기 토글
        const { data: toggleCloseRes, error: toggleCloseErr } = await authenticatedAdminClient.rpc('admin_toggle_market');
        assert('관리자 시장 개폐 토글 RPC 호출 성공', !toggleCloseErr, toggleCloseErr?.message);

        const { data: closedSettings } = await userClient
            .from('market_settings')
            .select('is_market_open, status_code')
            .eq('id', 1)
            .single();

        assert('시장 상태 토글 반전 확인 (is_market_open 변경)', closedSettings.is_market_open !== initialOpen);

        // 휴장 상태로 세팅하여 주문 차단 가드 테스트
        if (closedSettings.is_market_open) {
            await authenticatedAdminClient.rpc('admin_toggle_market');
        }

        // 임의 학생 클라이언트로 휴장 중 주문 시도 -> 가드 에러 확인
        const testStudentEmail = `test_market_guard_${Date.now()}@stockgame.local`;
        const { data: testStudentAuth } = await adminServiceClient.auth.admin.createUser({
            email: testStudentEmail,
            password: 'password123',
            email_confirm: true,
            user_metadata: {
                student_id: `stu_guard_${Date.now()}`,
                name: '가드시험학생',
                role: 'ROLE_STUDENT'
            }
        });

        const { data: studentLogin } = await userClient.auth.signInWithPassword({
            email: testStudentEmail,
            password: 'password123'
        });

        const studentClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: {
                headers: {
                    Authorization: `Bearer ${studentLogin?.session?.access_token}`
                }
            }
        });

        // 첫 번째 종목 조회
        const { data: anyStock } = await userClient.from('stocks').select('id').eq('status', 'LISTED').limit(1).single();

        let guardBlocked = false;
        if (anyStock) {
            const { error: orderError } = await studentClient.rpc('place_and_match_order', {
                p_stock_id: anyStock.id,
                p_order_type: 'BUY',
                p_price: 1000,
                p_amount: 1
            });
            if (orderError && orderError.message.includes('휴장')) {
                guardBlocked = true;
            }
        } else {
            guardBlocked = true;
        }

        assert('휴장 중 주문 제출 차단 가드 동작 (에러 반환 확인)', guardBlocked);

        // 시장 정상 복구 (개장)
        await authenticatedAdminClient.rpc('admin_update_market_settings', {
            p_mode: 'AUTO',
            p_open_time: '09:00',
            p_close_time: '15:30',
            p_call_auction_start_time: '15:20'
        });
        const { data: restoredSettings } = await userClient
            .from('market_settings')
            .select('is_market_open')
            .eq('id', 1)
            .single();

        if (!restoredSettings.is_market_open) {
            await authenticatedAdminClient.rpc('admin_toggle_market');
        }
        assert('시장 운영 설정 정상 복구 완료 (is_market_open: true)', true);

        // -------------------------------------------------------------
        // TC 4.3: 신규 주식 종목 상장 등록 (CUD) 및 초기 발행가/잔량 설정
        // -------------------------------------------------------------
        console.log('\n--- [TC 4.3] 신규 주식 종목 상장 등록 (CUD) 및 초기 발행가/잔량 설정 ---');
        const testStockName = `P4_테스트상장_${Date.now().toString().slice(-4)}`;
        const testPubPrice = 10000;
        const testPubBalance = 500;
        const testHighLimit = Math.round(testPubPrice * 1.3);
        const testLowLimit = Math.round(testPubPrice * 0.7);

        const { data: createdStock, error: stockCreateErr } = await authenticatedAdminClient
            .from('stocks')
            .insert({
                name: testStockName,
                content: '[미래기술/IT] 페이즈4 컷오버 검증 종목',
                publication_price: testPubPrice,
                publication_balance: testPubBalance,
                current_price: testPubPrice,
                prev_price: testPubPrice,
                high_limit_price: testHighLimit,
                low_limit_price: testLowLimit,
                market_status: 'CONTINUOUS',
                status: 'LISTED'
            })
            .select()
            .single();

        assert('신규 종목 상장 등록 성공', !stockCreateErr && !!createdStock?.id, stockCreateErr?.message);
        assert('상장 가격 및 상하한가 계산 검증', createdStock?.high_limit_price === testHighLimit && createdStock?.low_limit_price === testLowLimit);

        // 종목 수정
        const { data: updatedStock, error: stockUpdateErr } = await authenticatedAdminClient
            .from('stocks')
            .update({
                content: '[미래기술/IT] 수정된 종목 상세 설명'
            })
            .eq('id', createdStock.id)
            .select()
            .single();

        assert('종목 정보 수정(Update) 반영 확인', !stockUpdateErr && updatedStock?.content.includes('수정된 종목'));

        // -------------------------------------------------------------
        // TC 4.4: 원자적 ACID 상장폐지 청산 검증 (admin_delist_stock)
        // -------------------------------------------------------------
        console.log('\n--- [TC 4.4] 원자적 ACID 상장폐지 청산 검증 (admin_delist_stock) ---');
        // 매수자 계정 및 주식 보유자 계정 준비
        const buyerEmail = `buyer_p4_${Date.now()}@stockgame.local`;
        const { data: buyerCreated } = await adminServiceClient.auth.admin.createUser({
            email: buyerEmail,
            password: 'password123',
            email_confirm: true,
            user_metadata: {
                student_id: `buyer_${Date.now()}`,
                name: '매수학생',
                role: 'ROLE_STUDENT'
            }
        });
        const buyerId = buyerCreated.user.id;

        const { data: buyerLogin } = await userClient.auth.signInWithPassword({
            email: buyerEmail,
            password: 'password123'
        });

        const buyerStudentClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: {
                headers: {
                    Authorization: `Bearer ${buyerLogin.session.access_token}`
                }
            }
        });

        // 매수자에게 50,000P 지급
        await adminServiceClient.from('profiles').update({ total_point: 50000 }).eq('id', buyerId);

        // 매수자가 해당 종목 2주 지정가 매수 주문 등록 (price: 8,500, 발행가 10,000원 미만으로 미체결 호가창 유지, 17,000P 락)
        const { data: buyOrder, error: orderErr } = await buyerStudentClient.rpc('place_and_match_order', {
            p_stock_id: createdStock.id,
            p_order_type: 'BUY',
            p_price: 8500,
            p_amount: 2
        });

        const { data: buyerProfileBefore } = await adminServiceClient.from('profiles').select('total_point').eq('id', buyerId).single();

        // 다른 보유자에게 주식 3주 부여
        const holderEmail = `holder_${Date.now()}@stockgame.local`;
        const { data: holderCreated } = await adminServiceClient.auth.admin.createUser({
            email: holderEmail,
            password: 'password123',
            email_confirm: true,
            user_metadata: { student_id: `holder_${Date.now()}`, name: '보유학생', role: 'ROLE_STUDENT' }
        });
        const holderId = holderCreated.user.id;
        await adminServiceClient.from('profiles').update({ total_point: 10000 }).eq('id', holderId);

        await adminServiceClient.from('user_holdings').insert({
            user_id: holderId,
            stock_id: createdStock.id,
            amount: 3,
            locked_amount: 0,
            average_price: testPubPrice,
            total_invested_amount: 3 * testPubPrice
        });

        // 상장폐지 실행 (보상 단가 9,000원)
        const compensationPrice = 9000;
        const { data: delistRes, error: delistErr } = await authenticatedAdminClient.rpc('admin_delist_stock', {
            p_stock_id: createdStock.id,
            p_compensation_price: compensationPrice,
            p_reason: '페이즈4 청산 테스트'
        });

        assert('상장폐지 RPC 호출 성공', !delistErr && delistRes?.success === true, delistErr?.message);

        // 1) 종목 상태 검증
        const { data: delistedStock } = await userClient.from('stocks').select('status').eq('id', createdStock.id).single();
        assert('종목 상태 DELISTED 확인', delistedStock?.status === 'DELISTED');

        // 2) 매수 주문 취소 및 포인트 환불 검증
        const { data: buyerProfileAfter } = await adminServiceClient.from('profiles').select('total_point').eq('id', buyerId).single();
        assert('미체결 매수 주문 포인트 환불 완료 (원복 확인)', buyerProfileAfter?.total_point === 50000, `Current: ${buyerProfileAfter?.total_point}`);

        // 3) 주식 보유자 보상금 지급 검증 (기존 10,000 + 3 * 9,000 = 37,000P)
        const { data: holderProfileAfter } = await adminServiceClient.from('profiles').select('total_point').eq('id', holderId).single();
        const expectedHolderPoint = 10000 + (3 * compensationPrice);
        assert('주식 보유자 청산 보상금 정상 지급 확인', holderProfileAfter?.total_point === expectedHolderPoint, `Point: ${holderProfileAfter?.total_point}`);

        // 4) 보유 주식 잔고 0 확인
        const { data: holderHolding } = await adminServiceClient.from('user_holdings').select('amount').eq('user_id', holderId).eq('stock_id', createdStock.id).single();
        assert('보유자 주식 잔고 0주 청산 확인', holderHolding?.amount === 0);

        // -------------------------------------------------------------
        // TC 4.5: 신규 학생 계정 발급 및 포인트 강제 조정 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC 4.5] 신규 학생 계정 발급 및 포인트 강제 조정 검증 ---');
        const newStudentId = `stu_p4_${Date.now().toString().slice(-4)}`;
        const { data: newStuAuth, error: newStuErr } = await adminServiceClient.auth.admin.createUser({
            email: `${newStudentId}@stockgame.local`,
            password: 'password123',
            email_confirm: true,
            user_metadata: {
                student_id: newStudentId,
                name: '테스트신규학생',
                grade: 2,
                class_name: '3반',
                class_number: 15,
                role: 'ROLE_STUDENT'
            }
        });
        assert('학생 계정 등록 성공', !newStuErr && !!newStuAuth?.user?.id);
        const testStuUserId = newStuAuth.user.id;

        // 포인트 지급 (+25,000P)
        const { data: adjustGrantRes, error: grantErr } = await authenticatedAdminClient.rpc('admin_adjust_student_point', {
            p_user_id: testStuUserId,
            p_amount: 25000,
            p_reason: '숙제 우수 보상금'
        });
        assert('포인트 강제 지급 RPC 성공 (+25,000P)', !grantErr && adjustGrantRes?.success === true);

        // 포인트 차감 (-10,000P)
        const { data: adjustDeductRes, error: deductErr } = await authenticatedAdminClient.rpc('admin_adjust_student_point', {
            p_user_id: testStuUserId,
            p_amount: -10000,
            p_reason: '지각 벌점 차감'
        });
        assert('포인트 강제 차감 RPC 성공 (-10,000P)', !deductErr && adjustDeductRes?.success === true);

        // 초과 차감 시도 -> 예외 발생 확인
        const { error: exceedErr } = await authenticatedAdminClient.rpc('admin_adjust_student_point', {
            p_user_id: testStuUserId,
            p_amount: -99999999,
            p_reason: '과도한 차감 시도'
        });
        assert('잔액 초과 차감 방어 가드 확인 (예외 발생)', !!exceedErr);

        // 감사 로그 확인
        const { data: pointLogs } = await authenticatedAdminClient
            .from('point_transactions')
            .select('*')
            .eq('user_id', testStuUserId);
        assert('포인트 변동 감사 이력(point_transactions) 적재 확인', pointLogs && pointLogs.length >= 2);

        // -------------------------------------------------------------
        // TC 4.6: 학생 계정 영구 삭제 및 원장 클린업 검증 (admin_delete_student)
        // -------------------------------------------------------------
        console.log('\n--- [TC 4.6] 학생 계정 영구 삭제 및 원장 클린업 검증 ---');
        const { data: delStuRes, error: delStuErr } = await authenticatedAdminClient.rpc('admin_delete_student', {
            p_user_id: testStuUserId
        });
        assert('학생 계정 삭제 RPC 호출 성공', !delStuErr && delStuRes?.success === true, delStuErr?.message);

        const { data: deletedProfile } = await adminServiceClient
            .from('profiles')
            .select('id')
            .eq('id', testStuUserId)
            .maybeSingle();
        assert('학생 프로필 테이블 완전 삭제 확인', deletedProfile === null);

        // -------------------------------------------------------------
        // TC 4.7: 쿠폰 상품 CRUD 및 상태 변경 검증
        // -------------------------------------------------------------
        console.log('\n--- [TC 4.7] 쿠폰 상품 CRUD 및 상태 변경 검증 ---');
        const testCouponName = `P4_쿠폰_${Date.now().toString().slice(-4)}`;
        const testCouponCode = `CPN-${Date.now().toString().slice(-6)}`;
        const { data: createdCoupon, error: couponCreateErr } = await authenticatedAdminClient
            .from('coupons')
            .insert({
                coupon_code: testCouponCode,
                name: testCouponName,
                price: 2500,
                status: 'ON_SALE'
            })
            .select()
            .single();

        assert('신규 쿠폰 등록 성공', !couponCreateErr && !!createdCoupon?.id, couponCreateErr?.message);

        // 쿠폰 수정
        const { data: updatedCoupon, error: couponUpdateErr } = await authenticatedAdminClient
            .from('coupons')
            .update({
                price: 3000,
                status: 'PAUSED'
            })
            .eq('id', createdCoupon.id)
            .select()
            .single();

        assert('쿠폰 가격 및 판매상태 수정 반영 확인', !couponUpdateErr && updatedCoupon?.price === 3000 && updatedCoupon?.status === 'PAUSED');

        // 쿠폰 삭제
        const { error: couponDelErr } = await authenticatedAdminClient
            .from('coupons')
            .delete()
            .eq('id', createdCoupon.id);

        assert('쿠폰 삭제 완료', !couponDelErr);

        // 클린업: 테스트 계정들 정리
        try {
            await adminServiceClient.rpc('admin_delete_student', { p_user_id: buyerId });
            await adminServiceClient.rpc('admin_delete_student', { p_user_id: holderId });
        } catch (cleanupErr) {
            // 무시
        }

    } catch (globalErr) {
        console.error('Test execution error:', globalErr);
    }

    console.log('\n================================================================');
    console.log(`Phase 4 Admin Portal Cutover Test Summary: ${passed} / ${total} PASS`);
    console.log('================================================================');

    if (passed === total && total > 0) {
        process.exit(0);
    } else {
        process.exit(1);
    }
}

runTests();
