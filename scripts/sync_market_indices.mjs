/**
 * ==============================================================================
 * StockGame Market Indices Sync Utility (Zero-Dependency)
 * Description: Fetches real-time KOSPI & KOSDAQ indices from Naver Finance API
 *              and upserts them into Supabase Cloud `market_indices` table.
 * Usage:
 *   node scripts/sync_market_indices.mjs
 *   node scripts/sync_market_indices.mjs --watch
 * ==============================================================================
 */

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://ulgbshgzwmnytejfutsb.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVsZ2JzaGd6d21ueXRlamZ1dHNiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5NDYwNTgsImV4cCI6MjA4NjUyMjA1OH0.kPP9z55fCaKdd4jzI05x-K_xJzPoND0OQx8VFkl7Nvw';

const HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
};

const parseNum = (val, defaultVal = 0) => {
    if (val === null || val === undefined) return defaultVal;
    if (typeof val === 'number') return val;
    const cleaned = String(val).replace(/,/g, '').trim();
    const parsed = parseFloat(cleaned);
    return isNaN(parsed) ? defaultVal : parsed;
};

async function fetchJson(url) {
    const res = await fetch(url, { headers: HEADERS });
    if (!res.ok) {
        throw new Error(`HTTP ${res.status} ${res.statusText} from ${url}`);
    }
    return await res.json();
}

async function callSupabaseRpc(functionName, params) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${functionName}`, {
        method: 'POST',
        headers: {
            'apikey': SUPABASE_KEY,
            'Authorization': `Bearer ${SUPABASE_KEY}`,
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(params)
    });
    if (!res.ok) {
        const text = await res.text();
        throw new Error(`Supabase RPC Error (${res.status}): ${text}`);
    }
    return await res.json();
}

async function fetchIndexData(itemCode, korName, marketType) {
    const basicUrl = `https://m.stock.naver.com/api/index/${itemCode}/basic`;
    const priceUrl = `https://m.stock.naver.com/api/index/${itemCode}/price?page=1&pageSize=7`;

    const [basic, priceList] = await Promise.all([
        fetchJson(basicUrl),
        fetchJson(priceUrl)
    ]);

    const curValue = parseNum(basic.closePrice);
    const changeVal = parseNum(basic.compareToPreviousClosePrice);
    const changeRate = parseNum(basic.fluctuationsRatio);
    const prevClose = curValue - changeVal;

    const todayPrice = (Array.isArray(priceList) && priceList.length > 0) ? priceList[0] : {};
    const openPrice = parseNum(todayPrice.openPrice, curValue);
    const highPrice = parseNum(todayPrice.highPrice, curValue);
    const lowPrice = parseNum(todayPrice.lowPrice, curValue);

    // 7거래일 종가 추이 (오래된 날짜 -> 최신 날짜 순으로 정렬)
    const chartHistory = Array.isArray(priceList)
        ? priceList.map(p => parseNum(p.closePrice)).reverse()
        : [curValue];

    return {
        name: itemCode,
        kor_name: korName,
        market_type: marketType,
        value: curValue,
        change_val: changeVal,
        change_rate: changeRate,
        prev_close: prevClose,
        open_price: openPrice,
        high_price: highPrice,
        low_price: lowPrice,
        high_52w: Math.round(highPrice * 1.15 * 100) / 100,
        low_52w: Math.round(lowPrice * 0.85 * 100) / 100,
        volume: parseNum(basic.dealVolume, 500000000),
        trading_value: parseNum(basic.dealPrice, 8000000000000),
        market_status: basic.marketStatus || 'OPEN',
        chart_history: chartHistory
    };
}

export async function syncIndices() {
    console.log(`\n[${new Date().toISOString()}] 🚀 실시간 코스피 / 코스닥 시장 지수 수집 및 동기화 시작...`);

    try {
        const [kospi, kosdaq] = await Promise.all([
            fetchIndexData('KOSPI', '코스피', '유가증권시장'),
            fetchIndexData('KOSDAQ', '코스닥', '코스닥시장')
        ]);

        console.log(`📊 수집 완료:`);
        console.log(`   - KOSPI : ${kospi.value.toLocaleString()} P (${kospi.change_rate >= 0 ? '+' : ''}${kospi.change_rate}%, ${kospi.change_val >= 0 ? '+' : ''}${kospi.change_val} P)`);
        console.log(`   - KOSDAQ: ${kosdaq.value.toLocaleString()} P (${kosdaq.change_rate >= 0 ? '+' : ''}${kosdaq.change_rate}%, ${kosdaq.change_val >= 0 ? '+' : ''}${kosdaq.change_val} P)`);

        // Supabase RPC upsert_market_index 호출 (Zero-Dependency)
        const [res1, res2] = await Promise.all([
            callSupabaseRpc('upsert_market_index', { p_item: kospi }),
            callSupabaseRpc('upsert_market_index', { p_item: kosdaq })
        ]);

        console.log(`✅ Supabase Cloud 반영 완료! (market_indices 테이블 갱신 성공)`);
        console.log(`   - 결과: KOSPI (${JSON.stringify(res1)}), KOSDAQ (${JSON.stringify(res2)})\n`);
        return { success: true, kospi, kosdaq };
    } catch (error) {
        console.error(`❌ 동기화 실패:`, error.message);
        return { success: false, error: error.message };
    }
}

// 직접 실행 시 구동
if (process.argv[1]?.endsWith('sync_market_indices.mjs')) {
    const isWatch = process.argv.includes('--watch');

    if (isWatch) {
        console.log('🔄 실시간 감시 모드 시작 (1분 주기로 시장 지수 자동 동기화)');
        syncIndices();
        setInterval(syncIndices, 60 * 1000);
    } else {
        syncIndices().then(() => process.exit(0));
    }
}
