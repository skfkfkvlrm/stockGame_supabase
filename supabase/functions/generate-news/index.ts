import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") || "AIzaSyBLqQz8JAceXDZXOsT238vJgn0oqfK3zfI";
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") || "gemini-2.5-flash-lite";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Fallback templates in case Gemini API is unreachable or rate limited
const POSITIVE_TEMPLATES = [
  { headline: (name: string) => `[특징주] ${name}, 학급 내 수요 급증으로 시장 관심 집중`, content: (name: string) => `${name}에 대한 학생들의 거래 참여가 활발해지며 투자 심리가 크게 개선되고 있습니다.`, impactRate: 2.5 },
  { headline: (name: string) => `[호재] ${name}, 쉬는 시간 매점 인기 1위 등극`, content: (name: string) => `최근 신규 물량 입고와 함께 ${name}의 선호도가 급상승하며 학생들의 주목을 받고 있습니다.`, impactRate: 3.0 },
  { headline: (name: string) => `[기업이슈] ${name}, 신제품 출시에 따른 실적 개선 기대감`, content: (name: string) => `${name}의 혁신적인 개선 모델이 입소문을 타며 학급 내 관심도가 최고조에 달했습니다.`, impactRate: 2.0 },
  { headline: (name: string) => `[시장동향] ${name}, 대규모 공동구매 소식에 매수세 유입`, content: (name: string) => `학급 학생들의 단체 구매 수요가 확인되며 ${name}에 대한 긍정적 전망이 확산되고 있습니다.`, impactRate: 1.8 },
  { headline: (name: string) => `[속보] ${name}, 유저 만족도 조사에서 압도적 1위 기록`, content: (name: string) => `품질과 가성비 모두에서 높은 점수를 받으며 ${name}에 대한 신뢰도가 대폭 상승했습니다.`, impactRate: 2.8 },
  { headline: (name: string) => `[투자분석] ${name}, 방과 후 수요 확대에 따른 성장 모멘텀 확보`, content: (name: string) => `방과 후 활동 재개와 맞물려 ${name}의 소비 빈도가 늘어날 것으로 기대됩니다.`, impactRate: 2.2 }
];

const NEGATIVE_TEMPLATES = [
  { headline: (name: string) => `[시황] ${name}, 일시적 재고 부족 및 공급 지연 우려`, content: (name: string) => `유통 과정에서의 일시적 차질로 인해 ${name}의 수급 불균형 우려가 제기되고 있습니다.`, impactRate: -2.0 },
  { headline: (name: string) => `[악재] ${name}, 경쟁 대체 상품 등장으로 점유율 분산`, content: (name: string) => `유사 신제품들이 학급에 유입되면서 ${name}에 대한 단기적 선호도가 분산되고 있습니다.`, impactRate: -2.5 },
  { headline: (name: string) => `[특징주] ${name}, 차익 실현성 매도 물량 출회로 관망세`, content: (name: string) => `단기 급등 이후 학생들의 차익 실현 심리가 맞물리며 ${name}의 거래 회전율이 둔화되고 있습니다.`, impactRate: -1.5 },
  { headline: (name: string) => `[시장경고] ${name}, 가격 인상 소식에 소비자 반응 엇갈려`, content: (name: string) => `원가 상승에 따른 가격 조정 우려가 나오며 ${name}에 대한 보수적인 접근이 늘고 있습니다.`, impactRate: -2.2 },
  { headline: (name: string) => `[기업이슈] ${name}, 학급 규정 변경에 따른 사용 제한 우려`, content: (name: string) => `일부 사용 시간 조정 논의가 나오면서 ${name} 관련 단기 심리가 위축되고 있습니다.`, impactRate: -2.8 },
  { headline: (name: string) => `[증시뉴스] ${name}, 계절적 비수기 진입으로 수요 일시 둔화`, content: (name: string) => `학기 중 일정 변화로 인해 ${name}의 일일 소비량이 소폭 감소한 것으로 파악됩니다.`, impactRate: -1.8 }
];

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    let requestBody: any = {};
    if (req.method === "POST") {
      try {
        requestBody = await req.json();
      } catch {
        requestBody = {};
      }
    }

    // 1. 대상 종목 조회 (지정 종목 또는 무작위 상장 종목)
    let stockQuery = supabase
      .from("stocks")
      .select("id, name, current_price, publication_balance")
      .eq("status", "LISTED");

    if (requestBody.stockId || requestBody.stock_id) {
      stockQuery = stockQuery.eq("id", requestBody.stockId || requestBody.stock_id);
    }

    const { data: stocks, error: stockError } = await stockQuery;

    if (stockError || !stocks || stocks.length === 0) {
      return new Response(JSON.stringify({ error: "No active stocks found" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const targetStock = stocks[Math.floor(Math.random() * stocks.length)];

    // 2. 6:4 감성 비율 제어 (60% 호재, 40% 악재)
    const isPositive = requestBody.forceSentiment || requestBody.sentiment
      ? (requestBody.forceSentiment || requestBody.sentiment) === "POSITIVE"
      : Math.random() < 0.6;
    const targetSentiment = isPositive ? "POSITIVE" : "NEGATIVE";
    const sentimentLabel = isPositive ? "호재" : "악재";

    // 3. Google Gemini 2.5 Flash Lite API 호출
    let parsedNews: { headline: string; content: string; sentiment: string; impact_rate: number };
    let generatorUsed = "gemini-2.5-flash-lite";

    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 7000); // 7초 타임아웃

      const prompt = `당신은 초·중학교 가상 학급 모의투자 주식시장의 경제 전문 기자입니다.
학생들이 공감하고 흥미를 느낄 수 있는 현실감 있고 생동감 넘치는 가상 시황 뉴스 기사를 1건 작성하세요.

[종목 및 시장 정보]
- 종목명: ${targetStock.name}
- 현재 주가: ${targetStock.current_price?.toLocaleString() || 1000}원
- 감성 모드: 반드시 [${sentimentLabel}] 기사로 작성하세요. (${targetSentiment})
- 기사 소재 가이드: ${
        isPositive
          ? "학생들의 폭발적 수요 급증, 매점/학급 내 대유행, 신제품 입고 호평, 대규모 공동구매 소식, 유저 만족도 1위 등 긍정적 호재"
          : "일시적 수급 불균형, 공급 지연, 경쟁 대체재 등장에 따른 점유율 분산, 가격 인상 논란, 단기 차익실현 매물 출회 등 부정적 악재"
      }

반드시 아래 JSON 형식으로만 응답하세요:
{
  "headline": "[${sentimentLabel}] ${targetStock.name}, 매력적인 한 줄 헤드라인",
  "content": "학생들이 쉽게 이해하면서도 실제 경제 기사처럼 전문성이 느껴지는 2~3문장의 기사 본문",
  "sentiment": "${targetSentiment}",
  "impact_rate": ${isPositive ? 2.5 : -2.0}
}`;

      const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}`;
      const geminiRes = await fetch(geminiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0.8,
            responseMimeType: "application/json",
          },
        }),
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      if (!geminiRes.ok) {
        const errText = await geminiRes.text();
        throw new Error(`Gemini HTTP ${geminiRes.status}: ${errText}`);
      }

      const geminiData = await geminiRes.json();
      const rawText = geminiData.candidates?.[0]?.content?.parts?.[0]?.text;
      if (!rawText) throw new Error("Empty Gemini response");

      const rawObj = JSON.parse(rawText);

      parsedNews = {
        headline: rawObj.headline || `[${sentimentLabel}] ${targetStock.name}, 시장 관심 집중`,
        content: rawObj.content || `${targetStock.name}에 대한 학생들의 참여가 활발해지며 투자 심리가 크게 움직이고 있습니다.`,
        sentiment: targetSentiment,
        impact_rate: typeof rawObj.impact_rate === "number" ? rawObj.impact_rate : (isPositive ? 2.2 : -2.0),
      };
    } catch (geminiErr: any) {
      console.warn("[generate-news] Gemini API failed, using fallback template:", geminiErr.message);
      generatorUsed = "fallback-template";

      // 4. Gemini 호출 실패 시 템플릿 폴백
      const pool = isPositive ? POSITIVE_TEMPLATES : NEGATIVE_TEMPLATES;
      const tpl = pool[Math.floor(Math.random() * pool.length)];

      parsedNews = {
        headline: tpl.headline(targetStock.name),
        content: tpl.content(targetStock.name),
        sentiment: targetSentiment,
        impact_rate: tpl.impactRate,
      };
    }

    // 5. news 테이블에 인서트 (Supabase Realtime이 즉시 클라이언트로 브로드캐스트)
    const { data: insertedNews, error: insertError } = await supabase
      .from("news")
      .insert({
        stock_id: targetStock.id,
        headline: parsedNews.headline,
        content: parsedNews.content,
        sentiment: parsedNews.sentiment,
        impact_rate: parsedNews.impact_rate,
      })
      .select("*, stocks(id, name)")
      .single();

    if (insertError) {
      throw insertError;
    }

    return new Response(
      JSON.stringify({
        success: true,
        generator: generatorUsed,
        stock: {
          id: targetStock.id,
          name: targetStock.name,
          current_price: targetStock.current_price,
        },
        news: insertedNews,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
