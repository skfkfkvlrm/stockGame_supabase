import { createClient } from '../../stockGame_react/node_modules/@supabase/supabase-js/dist/index.mjs';

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:54321';
const ANON_KEY = process.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

console.log('================================================================');
console.log('🚀 Phase 1 Concurrency & RLS Security Penetration Test Suite');
console.log('Target:', SUPABASE_URL);
console.log('================================================================\n');

async function getOrRegisterStudent(idNumber, name) {
    const email = `test_student_${idNumber}@stockgame.local`;
    const password = 'TestPassword123!';
    const anonClient = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });

    // Try login
    let { data: loginData, error: loginErr } = await anonClient.auth.signInWithPassword({ email, password });
    if (!loginErr && loginData?.session) {
        const authedClient = createClient(SUPABASE_URL, ANON_KEY, {
            auth: { persistSession: false },
            global: { headers: { Authorization: `Bearer ${loginData.session.access_token}` } }
        });
        return { user: loginData.user, token: loginData.session.access_token, client: authedClient };
    }

    // Sign up
    const { data: signData, error: signErr } = await anonClient.auth.signUp({
        email,
        password,
        options: {
            data: {
                student_id: `TEST_${idNumber}`,
                name: name,
                grade: 2,
                class_name: '3반',
                class_number: idNumber,
                role: 'ROLE_STUDENT'
            }
        }
    });

    if (signErr) {
        throw new Error(`Signup failed for ${email}: ${signErr.message}`);
    }

    const token = signData.session?.access_token;
    const authedClient = createClient(SUPABASE_URL, ANON_KEY, {
        auth: { persistSession: false },
        global: { headers: { Authorization: `Bearer ${token}` } }
    });

    return { user: signData.user, token, client: authedClient };
}

async function runAudit() {
    let passedTests = 0;
    let totalTests = 0;

    function assert(desc, condition, detail = '') {
        totalTests++;
        if (condition) {
            passedTests++;
            console.log(`  ✅ [PASS] ${desc}`);
        } else {
            console.error(`  ❌ [FAIL] ${desc} - ${detail}`);
        }
    }

    console.log('[Step 1] Initializing Test Student Accounts (Alpha & Beta)...');
    const alpha = await getOrRegisterStudent(101, '학생알파');
    const beta = await getOrRegisterStudent(102, '학생베타');
    console.log(`  Alpha User ID: ${alpha.user.id}`);
    console.log(`  Beta User ID:  ${beta.user.id}\n`);

    // =========================================================================
    // SECTION 1: RLS PENETRATION TESTS
    // =========================================================================
    console.log('----------------------------------------------------------------');
    console.log('🔒 Section 1: Row Level Security (RLS) Penetration Attacks');
    console.log('----------------------------------------------------------------');

    // Attack 1: Student Alpha attempts to cancel Student Beta's order
    console.log('\n[Attack 1] Student Alpha attempts to cancel Student Beta order:');
    // Beta places an order first
    const { data: betaOrderRes, error: betaOrderErr } = await beta.client.rpc('place_and_match_order', {
        p_stock_id: 1,
        p_order_type: 'BUY',
        p_price: 600, // Below current price and publication price so it stays PENDING
        p_amount: 5
    });
    
    assert('Beta placed pending BUY order at 600 P', !betaOrderErr && betaOrderRes?.order_id, JSON.stringify(betaOrderErr));
    const betaOrderId = betaOrderRes?.order_id;

    if (betaOrderId) {
        // Alpha tries to cancel Beta's order via RPC
        const { data: stealCancel, error: stealCancelErr } = await alpha.client.rpc('cancel_stock_order', {
            p_order_id: betaOrderId
        });
        assert(
            'Alpha RPC cancel on Beta order is blocked with permission error',
            stealCancelErr && stealCancelErr.message.includes('본인의 주문만 취소할 수 있습니다'),
            stealCancelErr?.message || 'Expected permission rejection'
        );

        // Alpha tries to direct PATCH orders table via PostgREST
        const { data: directPatch, error: directPatchErr } = await alpha.client
            .from('orders')
            .update({ status: 'CANCELLED' })
            .eq('id', betaOrderId);
        
        // RLS prevents updating other's rows (affects 0 rows or errors)
        const { data: verifyOrder } = await beta.client.from('orders').select('status').eq('id', betaOrderId).single();
        assert(
            'Direct PostgREST PATCH on Beta order has zero effect (RLS blocked)',
            verifyOrder?.status === 'PENDING',
            `Status was modified to: ${verifyOrder?.status}`
        );

        // Clean up Beta's order
        await beta.client.rpc('cancel_stock_order', { p_order_id: betaOrderId });
    }

    // Attack 2: Student Alpha attempts to forge total_point via PostgREST PATCH
    console.log('\n[Attack 2] Student Alpha attempts direct Point Forgery:');
    const { data: pointForge, error: pointForgeErr } = await alpha.client
        .from('profiles')
        .update({ total_point: 999999999 })
        .eq('id', alpha.user.id);
    
    // Check if total_point was modified
    const { data: profileCheck } = await alpha.client.from('profiles').select('total_point').eq('id', alpha.user.id).single();
    assert(
        'Direct PATCH on profiles.total_point is blocked (RLS enforced)',
        profileCheck?.total_point < 999999999,
        `Current points: ${profileCheck?.total_point}`
    );

    // Attack 3: Student Alpha attempts to forge shares in user_holdings
    console.log('\n[Attack 3] Student Alpha attempts Share Injection into user_holdings:');
    const { data: shareForge, error: shareForgeErr } = await alpha.client
        .from('user_holdings')
        .insert({ user_id: alpha.user.id, stock_id: 1, amount: 99999 });

    assert(
        'Direct INSERT into user_holdings is rejected by RLS',
        shareForgeErr !== null,
        'Expected RLS rejection'
    );

    // Attack 4: Student Alpha attempts to inject fake filled order
    console.log('\n[Attack 4] Student Alpha attempts Fake Order Injection into orders:');
    const { data: orderForge, error: orderForgeErr } = await alpha.client
        .from('orders')
        .insert({ user_id: alpha.user.id, stock_id: 1, order_type: 'BUY', price: 100, amount: 10, remain_amount: 0, status: 'FILLED' });

    assert(
        'Direct INSERT into orders is rejected by RLS',
        orderForgeErr !== null,
        'Expected RLS rejection'
    );


    // =========================================================================
    // SECTION 2: CONCURRENCY & RACE CONDITION TESTS
    // =========================================================================
    console.log('\n----------------------------------------------------------------');
    console.log('⚡ Section 2: Concurrency, Deadlock & Race Condition Tests');
    console.log('----------------------------------------------------------------');

    // Test 1: Double Cancel Race Condition
    console.log('\n[Test 1] Double Cancel Race Condition (Zero Double Refund):');
    const { data: raceOrder } = await alpha.client.rpc('place_and_match_order', {
        p_stock_id: 1,
        p_order_type: 'BUY',
        p_price: 610,
        p_amount: 10
    });

    if (raceOrder?.order_id) {
        const orderId = raceOrder.order_id;
        // Fire two simultaneous cancel calls
        const [cancel1, cancel2] = await Promise.allSettled([
            alpha.client.rpc('cancel_stock_order', { p_order_id: orderId }),
            alpha.client.rpc('cancel_stock_order', { p_order_id: orderId })
        ]);

        const oneSucceeded = (cancel1.status === 'fulfilled' && !cancel1.value.error) || (cancel2.status === 'fulfilled' && !cancel2.value.error);
        const oneRejected = (cancel1.status === 'fulfilled' && cancel1.value.error) || (cancel2.status === 'fulfilled' && cancel2.value.error) || cancel1.status === 'rejected' || cancel2.status === 'rejected';

        assert('Exactly one cancel succeeds in concurrent race', oneSucceeded && oneRejected);
    }

    // Test 2: Concurrent Multi-Student Trading (Deadlock Prevention)
    console.log('\n[Test 2] Multi-User Concurrent Trading & Deadlock Stress:');
    const students = [];
    for (let i = 103; i <= 107; i++) {
        students.push(await getOrRegisterStudent(i, `동시학생_${i}`));
    }

    console.log(`  Spawning 5 concurrent students submitting simultaneous opposing orders...`);
    const concurrentPromises = [];
    let deadlockErrors = 0;
    let successCount = 0;

    for (let round = 0; round < 10; round++) {
        for (const stu of students) {
            const isBuy = Math.random() > 0.5;
            const price = 850 + Math.floor(Math.random() * 20); // 850 ~ 870
            const amount = 1 + Math.floor(Math.random() * 3);

            concurrentPromises.push(
                stu.client.rpc('place_and_match_order', {
                    p_stock_id: 1,
                    p_order_type: isBuy ? 'BUY' : 'SELL',
                    p_price: price,
                    p_amount: amount
                }).then(res => {
                    if (res.error) {
                        if (res.error.message.includes('deadlock') || res.error.code === '40P01') {
                            deadlockErrors++;
                        }
                    } else {
                        successCount++;
                    }
                    return res;
                }).catch(e => {
                    if (e.message.includes('deadlock')) deadlockErrors++;
                })
            );
        }
    }

    await Promise.all(concurrentPromises);
    console.log(`  Completed ${concurrentPromises.length} concurrent orders. Successes: ${successCount}, Deadlocks: ${deadlockErrors}`);

    assert('Zero deadlock detected (40P01 = 0)', deadlockErrors === 0, `Deadlocks observed: ${deadlockErrors}`);
    assert('High concurrency orders processed successfully', successCount > 0);


    // =========================================================================
    // SECTION 3: RECONCILIATION & ASSET CONSERVATION AUDIT
    // =========================================================================
    console.log('\n----------------------------------------------------------------');
    console.log('⚖️ Section 3: Asset Conservation & Reconciliation Audit');
    console.log('----------------------------------------------------------------');

    // Verify negative balances
    const { data: negProfiles } = await alpha.client.from('profiles').select('id, total_point').lt('total_point', 0);
    assert('Zero negative point balances across all profiles', (negProfiles || []).length === 0, JSON.stringify(negProfiles));

    const { data: negHoldings } = await alpha.client.from('user_holdings').select('id, amount, locked_amount').or('amount.lt.0,locked_amount.lt.0');
    assert('Zero negative stock balances across all holdings', (negHoldings || []).length === 0, JSON.stringify(negHoldings));

    console.log('\n================================================================');
    console.log(`📊 Phase 1 Audit Summary: ${passedTests} / ${totalTests} Passed (${((passedTests / totalTests) * 100).toFixed(1)}%)`);
    console.log('================================================================\n');

    if (passedTests === totalTests) {
        console.log('🎉 ALL PHASE 1 CONCURRENCY & SECURITY CHECKS PASSED PERFECTLY!\n');
        process.exit(0);
    } else {
        console.error('⚠️ SOME AUDIT CHECKS FAILED. Review logs above.\n');
        process.exit(1);
    }
}

runAudit().catch(err => {
    console.error('Fatal Audit Error:', err);
    process.exit(1);
});
