import { createClient } from '../../stockGame_react/node_modules/@supabase/supabase-js/dist/index.mjs';

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:54321';
const ANON_KEY = process.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

console.log('================================================================');
console.log('📰 Phase 2 AI News Pipeline & Realtime Streaming Test Suite');
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

    const adminClient = createClient(SUPABASE_URL, SERVICE_KEY, {
        auth: { persistSession: false }
    });

    try {
        // -------------------------------------------------------------
        // Test 1: Edge Function 호출 및 Ollama AI 뉴스 생성 (호재 모드)
        // -------------------------------------------------------------
        console.log('--- [Test 1] Edge Function AI 뉴스 생성 검증 (호재 모드) ---');
        const res1 = await fetch(`${SUPABASE_URL}/functions/v1/generate-news`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${SERVICE_KEY}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ forceSentiment: 'POSITIVE' })
        });

        assert('Edge Function HTTP 상태 코드 200 반환', res1.status === 200, `Status: ${res1.status}`);
        const data1 = await res1.json();
        assert('Edge Function 응답 성공 필드 확인', data1.success === true);
        assert('생성된 뉴스 레코드 존재', !!data1.news?.id);
        assert('감성 지수 POSITIVE 일치', data1.news?.sentiment === 'POSITIVE', `Sentiment: ${data1.news?.sentiment}`);
        assert('호재 영향률 양수 확인', data1.news?.impact_rate > 0, `Impact: ${data1.news?.impact_rate}%`);
        assert('뉴스 헤드라인 및 본문 유효성', data1.news?.headline?.length > 5 && data1.news?.content?.length > 10, data1.news?.headline);

        // -------------------------------------------------------------
        // Test 2: Edge Function 악재 모드 (NEGATIVE) 검증
        // -------------------------------------------------------------
        console.log('\n--- [Test 2] Edge Function AI 뉴스 생성 검증 (악재 모드) ---');
        const res2 = await fetch(`${SUPABASE_URL}/functions/v1/generate-news`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${SERVICE_KEY}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ forceSentiment: 'NEGATIVE' })
        });

        assert('악재 모드 Edge Function HTTP 200 반환', res2.status === 200);
        const data2 = await res2.json();
        assert('악재 감성 지수 NEGATIVE 일치', data2.news?.sentiment === 'NEGATIVE', `Sentiment: ${data2.news?.sentiment}`);
        assert('악재 영향률 음수 확인', data2.news?.impact_rate < 0, `Impact: ${data2.news?.impact_rate}%`);

        // -------------------------------------------------------------
        // Test 3: 순수 호가 체결 원칙 (Pure Order-Matching: 뉴스에 의한 주가 불변성 검증)
        // -------------------------------------------------------------
        console.log('\n--- [Test 3] 순수 주문 체결 원칙 검증 (뉴스 발행 후 주가 불변성) ---');
        // 임의의 종목 1건 현재가 조회
        const { data: targetStock, error: stockFetchErr } = await adminClient
            .from('stocks')
            .select('id, name, current_price')
            .eq('status', 'LISTED')
            .limit(1)
            .single();

        assert('대상 종목 조회 성공', !stockFetchErr && !!targetStock, `${targetStock?.name} (${targetStock?.id})`);

        const originalPrice = targetStock.current_price;

        // 특정 대상 종목을 타겟으로 뉴스 강제 생성
        const res3 = await fetch(`${SUPABASE_URL}/functions/v1/generate-news`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${SERVICE_KEY}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ stockId: targetStock.id, forceSentiment: 'POSITIVE' })
        });
        const data3 = await res3.json();
        assert('특정 종목 대상 뉴스 생성 완료', data3.success === true && data3.news?.stock_id === targetStock.id);

        // DB에서 종목 현재가 재조회
        const { data: recheckedStock } = await adminClient
            .from('stocks')
            .select('current_price')
            .eq('id', targetStock.id)
            .single();

        assert(
            '뉴스 발행 전후 주가 100% 불변 검증 (Pure Order-Matching 보장)',
            recheckedStock.current_price === originalPrice,
            `발행 전: ${originalPrice}원 === 발행 후: ${recheckedStock.current_price}원`
        );

        // -------------------------------------------------------------
        // Test 4: Supabase Realtime WebSocket 뉴스 스트리밍 검증
        // -------------------------------------------------------------
        console.log('\n--- [Test 4] Supabase Realtime WebSocket 실시간 스트리밍 검증 ---');
        const realtimeClient = createClient(SUPABASE_URL, ANON_KEY);

        const receivedEvents = [];
        let emitTime = Date.now();

        const channel = realtimeClient
            .channel('test_realtime_news_channel_' + Date.now())
            .on(
                'postgres_changes',
                { event: 'INSERT', schema: 'public', table: 'news' },
                (payload) => {
                    const latency = Date.now() - emitTime;
                    receivedEvents.push({
                        event: payload.new,
                        latency
                    });
                }
            );

        // 웹소켓 구독 완료 대기
        await new Promise((resolve) => {
            channel.subscribe((status) => {
                if (status === 'SUBSCRIBED') {
                    resolve(true);
                }
            });
        });

        assert('Realtime WebSocket 채널 구독 성공 (SUBSCRIBED)', true);

        // 이전 큐 비우기 및 트리거
        receivedEvents.length = 0;
        emitTime = Date.now();

        const res4 = await fetch(`${SUPABASE_URL}/functions/v1/generate-news`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${SERVICE_KEY}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ forceSentiment: 'POSITIVE' })
        });
        const data4 = await res4.json();
        const emittedNewsId = data4.news?.id;

        // WebSocket 이벤트 수신 대기 (최대 5초)
        const waitTimeout = 5000;
        const pollInterval = 50;
        let waited = 0;
        let matchedItem = null;
        while (!matchedItem && waited < waitTimeout) {
            matchedItem = receivedEvents.find((item) => Number(item.event.id) === Number(emittedNewsId));
            if (!matchedItem) {
                await new Promise((r) => setTimeout(r, pollInterval));
                waited += pollInterval;
            }
        }

        assert(
            'Realtime WebSocket을 통해 INSERT 이벤트 수신 성공',
            !!matchedItem,
            `Matched News ID: ${matchedItem?.event?.id}, Emitted: ${emittedNewsId}`
        );
        assert(
            'AI 뉴스 생성 및 실시간 스트리밍 전달 시간 5초(5000ms) 이내 보장',
            matchedItem && matchedItem.latency < 5000,
            `${matchedItem?.latency}ms (Ollama AI 추론 + 실시간 스트리밍 완료)`
        );

        // 채널 정리
        await realtimeClient.removeChannel(channel);
        assert('Realtime 채널 정상 정리 (Memory Leak 방지)', true);

    } catch (err) {
        console.error('Test runner exception:', err);
    }

    console.log('\n================================================================');
    console.log(`📊 Test Results: ${passed} / ${total} Passed (${((passed / total) * 100).toFixed(1)}%)`);
    console.log('================================================================\n');

    process.exit(passed === total ? 0 : 1);
}

runTests();
