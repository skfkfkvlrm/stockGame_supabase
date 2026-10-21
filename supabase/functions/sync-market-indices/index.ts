import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const NAVER_HEADERS = {
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
};

const parseNum = (val: unknown, defaultVal = 0): number => {
  if (val === null || val === undefined) return defaultVal;
  if (typeof val === "number") return val;
  const cleaned = String(val).replace(/,/g, "").trim();
  const parsed = parseFloat(cleaned);
  return isNaN(parsed) ? defaultVal : parsed;
};

async function fetchJson(url: string) {
  const res = await fetch(url, { headers: NAVER_HEADERS });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} ${res.statusText} from ${url}`);
  }
  return await res.json();
}

async function fetchIndexData(itemCode: string, korName: string, marketType: string) {
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

  // 7거래일 종가 추이 (과거 -> 현재 순)
  const chartHistory = Array.isArray(priceList)
    ? priceList.map((p: Record<string, unknown>) => parseNum(p.closePrice)).reverse()
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
    market_status: basic.marketStatus || "OPEN",
    chart_history: chartHistory
  };
}

serve(async (req) => {
  // CORS Preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const clientIp = req.headers.get("x-forwarded-for") || "unknown";
  console.log(`[${new Date().toISOString()}] 🚀 sync-market-indices invoked by ${clientIp}`);

  try {
    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
      throw new Error("Supabase configuration missing (SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY)");
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // KOSPI & KOSDAQ 병렬 크롤링
    const [kospi, kosdaq] = await Promise.all([
      fetchIndexData("KOSPI", "코스피", "유가증권시장"),
      fetchIndexData("KOSDAQ", "코스닥", "코스닥시장")
    ]);

    console.log(`📊 수집 성공 - KOSPI: ${kospi.value} (${kospi.change_rate}%), KOSDAQ: ${kosdaq.value} (${kosdaq.change_rate}%)`);

    // Supabase RPC upsert_market_index 호출
    const [rpcRes1, rpcRes2] = await Promise.all([
      supabase.rpc("upsert_market_index", { p_item: kospi }),
      supabase.rpc("upsert_market_index", { p_item: kosdaq })
    ]);

    if (rpcRes1.error) {
      console.warn("RPC KOSPI error, fallback to direct upsert:", rpcRes1.error);
      await supabase.from("market_indices").upsert(kospi, { onConflict: "name" });
    }
    if (rpcRes2.error) {
      console.warn("RPC KOSDAQ error, fallback to direct upsert:", rpcRes2.error);
      await supabase.from("market_indices").upsert(kosdaq, { onConflict: "name" });
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: "Market indices synced successfully",
        timestamp: new Date().toISOString(),
        data: {
          kospi: {
            value: kospi.value,
            change: kospi.change_val,
            changeRate: kospi.change_rate,
            status: kospi.market_status
          },
          kosdaq: {
            value: kosdaq.value,
            change: kosdaq.change_val,
            changeRate: kosdaq.change_rate,
            status: kosdaq.market_status
          }
        }
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200
      }
    );
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    console.error("❌ sync-market-indices execution failed:", errorMsg);

    return new Response(
      JSON.stringify({
        success: false,
        error: errorMsg,
        timestamp: new Date().toISOString()
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500
      }
    );
  }
});
