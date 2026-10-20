import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") || "";
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") || "gemini-1.5-flash";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// =========================================================================
// 초·중·고 학급 가상 모의투자 특화 Fallback 템플릿 36종 (호재 18종 + 악재 18종)
// =========================================================================

const POSITIVE_TEMPLATES = [
  { headline: (name: string) => `[특징주] ${name}, 학급 내 수요 급증으로 시장 관심 집중`, content: (name: string) => `${name}에 대한 학생들의 거래 참여가 활발해지며 투자 심리가 크게 개선되고 있습니다.`, impactRate: 2.5 },
  { headline: (name: string) => `[호재] ${name}, 쉬는 시간 매점 인기 1위 등극`, content: (name: string) => `최근 신규 물량 입고와 함께 ${name}의 선호도가 급상승하며 학생들의 주목을 받고 있습니다.`, impactRate: 3.0 },
  { headline: (name: string) => `[기업이슈] ${name}, 신제품 출시에 따른 실적 개선 기대감`, content: (name: string) => `${name}의 혁신적인 개선 모델이 입소문을 타며 학급 내 관심도가 최고조에 달했습니다.`, impactRate: 2.0 },
  { headline: (name: string) => `[시장동향] ${name}, 대규모 공동구매 소식에 매수세 유입`, content: (name: string) => `학급 학생들의 단체 구매 수요가 확인되며 ${name}에 대한 긍정적 전망이 확산되고 있습니다.`, impactRate: 1.8 },
  { headline: (name: string) => `[속보] ${name}, 유저 만족도 조사에서 압도적 1위 기록`, content: (name: string) => `품질과 가성비 모두에서 높은 점수를 받으며 ${name}에 대한 신뢰도가 대폭 상승했습니다.`, impactRate: 2.8 },
  { headline: (name: string) => `[투자분석] ${name}, 방과 후 수요 확대에 따른 성장 모멘텀 확보`, content: (name: string) => `방과 후 활동 재개와 맞물려 ${name}의 소비 빈도가 늘어날 것으로 기대됩니다.`, impactRate: 2.2 },
  { headline: (name: string) => `[특징주] ${name}, 교내 학생 인플루언서 추천 열풍에 입소문 확산`, content: (name: string) => `교내 인기 학생들의 긍정적인 사용 후기가 퍼지며 ${name}의 매수세가 가파르게 상승하고 있습니다.`, impactRate: 2.6 },
  { headline: (name: string) => `[호재] ${name}, 매점 신규 입고 즉시 전량 매진 기록`, content: (name: string) => `오늘 아침 매점에 입고된 ${name} 물량이 쉬는 시간 10분 만에 완판되며 폭발적인 인기를 입증했습니다.`, impactRate: 3.2 },
  { headline: (name: string) => `[시황] ${name}, 체육대회 및 학급 축제 시즌 맞아 소비 급증 기대`, content: (name: string) => `다가오는 학급 행사 시즌을 앞두고 ${name}에 대한 사전 예약 및 수요가 집중되고 있습니다.`, impactRate: 2.1 },
  { headline: (name: string) => `[기업이슈] ${name}, 개선된 품질 및 가성비 호평으로 재구매율 급상승`, content: (name: string) => `소비자 피드백을 반영한 업그레이드 버전이 출시되면서 ${name}의 재구매 의향이 역대 최고치를 기록했습니다.`, impactRate: 2.4 },
  { headline: (name: string) => `[시장동향] ${name}, 방과 후 자습실 간식 필수템으로 급부상`, content: (name: string) => `시험 기간을 앞두고 자습실과 도서관을 이용하는 학생들 사이에서 ${name}의 소비가 꾸준히 증가하고 있습니다.`, impactRate: 1.9 },
  { headline: (name: string) => `[속보] ${name}, 학급 모의투자 대회 핵심 인기 종목 선정`, content: (name: string) => `모의투자 참가 학생들의 포트폴리오 편입 비중 1위를 차지하며 시장 유동성을 주도하고 있습니다.`, impactRate: 2.7 },
  { headline: (name: string) => `[투자분석] ${name}, 신학기 학용품 단체 주문 계약 체결`, content: (name: string) => `학급 자치회 차원의 단체 공급 계약이 성사되면서 ${name}의 안정적인 매출 기반이 확보되었습니다.`, impactRate: 2.3 },
  { headline: (name: string) => `[호재] ${name}, 또래 커뮤니티 입소문 타며 브랜드 선호도 1위 달성`, content: (name: string) => `학생들이 활발히 이용하는 소통 채널에서 ${name}에 대한 긍정 평가가 급증하고 있습니다.`, impactRate: 2.5 },
  { headline: (name: string) => `[시황] ${name}, 기관 매수세 유입과 유사한 단체 구매 급증세 지속`, content: (name: string) => `모둠별 프로젝트 준비를 위한 대량 구매가 이어지며 주가 상승 탄력이 강화되고 있습니다.`, impactRate: 2.0 },
  { headline: (name: string) => `[기업이슈] ${name}, 친환경 패키징 도입 소식에 학생들 긍정 반응`, content: (name: string) => `지속 가능한 가치를 반영한 리뉴얼 소식에 환경 동아리를 중심으로 호평이 잇따르고 있습니다.`, impactRate: 1.7 },
  { headline: (name: string) => `[시장동향] ${name}, 점심시간 매점 앞 대기줄 형성... 인기 폭발`, content: (name: string) => `점심시간 매점 개시와 동시에 ${name}을 구매하려는 학생들이 몰려 장사진을 이루었습니다.`, impactRate: 2.9 },
  { headline: (name: string) => `[속보] ${name}, 깜짝 할인 이벤트에 오픈런 행렬 이어져`, content: (name: string) => `한정 수량 이벤트 소식이 전해지며 시작 전부터 큰 관심을 모았고 단기 매수세가 최고조에 달했습니다.`, impactRate: 3.1 }
];

const NEGATIVE_TEMPLATES = [
  { headline: (name: string) => `[시황] ${name}, 일시적 재고 부족 및 공급 지연 우려`, content: (name: string) => `유통 과정에서의 일시적 차질로 인해 ${name}의 수급 불균형 우려가 제기되고 있습니다.`, impactRate: -2.0 },
  { headline: (name: string) => `[악재] ${name}, 경쟁 대체 상품 등장으로 점유율 분산`, content: (name: string) => `유사 신제품들이 학급에 유입되면서 ${name}에 대한 단기적 선호도가 분산되고 있습니다.`, impactRate: -2.5 },
  { headline: (name: string) => `[특징주] ${name}, 차익 실현성 매도 물량 출회로 관망세`, content: (name: string) => `단기 급등 이후 학생들의 차익 실현 심리가 맞물리며 ${name}의 거래 회전율이 둔화되고 있습니다.`, impactRate: -1.5 },
  { headline: (name: string) => `[시장경고] ${name}, 가격 인상 소식에 소비자 반응 엇갈려`, content: (name: string) => `원가 상승에 따른 가격 조정 우려가 나오며 ${name}에 대한 보수적인 접근이 늘고 있습니다.`, impactRate: -2.2 },
  { headline: (name: string) => `[기업이슈] ${name}, 학급 규정 변경에 따른 사용 제한 우려`, content: (name: string) => `일부 사용 시간 조정 논의가 나오면서 ${name} 관련 단기 심리가 위축되고 있습니다.`, impactRate: -2.8 },
  { headline: (name: string) => `[증시뉴스] ${name}, 계절적 비수기 진입으로 수요 일시 둔화`, content: (name: string) => `학기 중 일정 변화로 인해 ${name}의 일일 소비량이 소폭 감소한 것으로 파악됩니다.`, impactRate: -1.8 },
  { headline: (name: string) => `[악재] ${name}, 매점 단기 입고 중단 소식에 투자 심리 위축`, content: (name: string) => `제조사 생산 일정 차질로 다음 주까지 신규 입고가 보류된다는 소식에 매수세가 주춤하고 있습니다.`, impactRate: -3.0 },
  { headline: (name: string) => `[시황] ${name}, 단기 급등에 따른 쉬는 시간 차익실현 매물 급증`, content: (name: string) => `목표 수익률에 도달한 투자자들의 매도세가 쏟아지며 주가 상승세가 일시 제한되고 있습니다.`, impactRate: -1.9 },
  { headline: (name: string) => `[투자경고] ${name}, 동종 경쟁사의 파격 프로모션으로 고객 이탈 우려`, content: (name: string) => `경쟁 상품의 덤 증정 행사로 인해 ${name}의 상대적 가격 경쟁력이 시험대에 올랐습니다.`, impactRate: -2.4 },
  { headline: (name: string) => `[기업이슈] ${name}, 유통 과정의 일시적 차질로 편의점/매점 공급 차질`, content: (name: string) => `물류 배송 차량 정비 문제로 일부 품목의 공급이 반나절 이상 지연되고 있습니다.`, impactRate: -2.1 },
  { headline: (name: string) => `[시장동향] ${name}, 소비 트렌드 변화에 따른 단기 수요 정체 국면`, content: (name: string) => `학생들의 주된 관심사가 다른 테마로 이동하면서 ${name}의 거래량이 감소 추세를 보이고 있습니다.`, impactRate: -1.7 },
  { headline: (name: string) => `[속보] ${name}, 유사 모조품 유통 주의보 발령에 시장 관망세`, content: (name: string) => `비공식 유통 제품 관련 주의 안내가 전달되면서 정품 확인 전까지 구매를 미루는 분위기입니다.`, impactRate: -2.6 },
  { headline: (name: string) => `[증시뉴스] ${name}, 시험 기간 진입에 따른 교내 간식 소비 일시 급감`, content: (name: string) => `집중 자습 분위기가 확산되며 매점 방문 빈도가 줄어 단기 수요 둔화가 불가피할 전망입니다.`, impactRate: -1.6 },
  { headline: (name: string) => `[악재] ${name}, 학생 만족도 조사에서 일부 불만 사항 접수`, content: (name: string) => `최근 제조 로트의 용량 변경에 대한 아쉬운 피드백이 나오며 투자자 경계감이 높아졌습니다.`, impactRate: -2.3 },
  { headline: (name: string) => `[시황] ${name}, 매수세 둔화 및 매도 우위 속 단기 가격 조정세`, content: (name: string) => `신규 매수 유입이 잠잠해진 가운데 단기 관망세를 나타내며 조정을 거치고 있습니다.`, impactRate: -1.8 },
  { headline: (name: string) => `[기업이슈] ${name}, 원자재 가격 상승 압박으로 마진율 축소 우려`, content: (name: string) => `포장재 및 원부자재 단가 인상으로 단기적인 실적 방어 부담이 가중될 것이라는 분석입니다.`, impactRate: -2.0 },
  { headline: (name: string) => `[투자경고] ${name}, 과도한 단기 투기성 매수에 따른 과열 경고등`, content: (name: string) => `펀더멘털을 벗어난 단기 급등세에 시장 관리 주체가 변동성 유의 안내를 게시했습니다.`, impactRate: -2.7 },
  { headline: (name: string) => `[시장경고] ${name}, 학급 내 대체 취미 활동 등장으로 관심 분산`, content: (name: string) => `새로운 보드게임 및 스포츠 활동이 인기를 끌며 기존 ${name}에 대한 쏠림이 완화되고 있습니다.`, impactRate: -2.2 }
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

    // 3. 최근 발행된 뉴스 5건 조회하여 중복 방지 (Anti-Repetition Grounding)
    const { data: recentNewsData } = await supabase
      .from("news")
      .select("headline")
      .order("created_at", { ascending: false })
      .limit(5);

    const recentHeadlines = (recentNewsData || []).map((n: any) => n.headline || "");

    // 4. Google Gemini API 호출 시도
    let parsedNews: { headline: string; content: string; sentiment: string; impact_rate: number };
    let generatorUsed = "gemini-api";

    let geminiSuccess = false;
    if (GEMINI_API_KEY && GEMINI_API_KEY.trim().length > 10) {
      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 6000); // 6초 타임아웃

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

[최근 발행된 뉴스 헤드라인 (이와 유사한 문장 구조는 절대 피하세요)]:
${recentHeadlines.map((h: string) => `- ${h}`).join("\n")}

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
              temperature: 0.85,
              responseMimeType: "application/json",
            },
          }),
          signal: controller.signal,
        });

        clearTimeout(timeoutId);

        if (geminiRes.ok) {
          const geminiData = await geminiRes.json();
          const rawText = geminiData.candidates?.[0]?.content?.parts?.[0]?.text;
          if (rawText) {
            const rawObj = JSON.parse(rawText);
            parsedNews = {
              headline: rawObj.headline || `[${sentimentLabel}] ${targetStock.name}, 시장 관심 집중`,
              content: rawObj.content || `${targetStock.name}에 대한 학생들의 참여가 활발해지며 투자 심리가 크게 움직이고 있습니다.`,
              sentiment: targetSentiment,
              impact_rate: typeof rawObj.impact_rate === "number" ? rawObj.impact_rate : (isPositive ? 2.2 : -2.0),
            };
            geminiSuccess = true;
          }
        }
      } catch (geminiErr: any) {
        console.warn("[generate-news] Gemini API call skipped/failed:", geminiErr.message);
      }
    }

    // 5. Gemini 호출 실패 또는 미설정 시: 36종 템플릿 + 최근 중복 배제 알고리즘 가동
    if (!geminiSuccess) {
      generatorUsed = "anti-repetition-template-engine";

      const pool = isPositive ? POSITIVE_TEMPLATES : NEGATIVE_TEMPLATES;

      // 최근 5개 뉴스 헤드라인과 겹치지 않는 템플릿 필터링
      const nonCollidingTemplates = pool.filter((tpl) => {
        const testHeadline = tpl.headline(targetStock.name);
        // 문장 뒤쪽 10글자 핵심 문구 추출하여 최근 헤드라인에 포함되었는지 검사
        const tailSnippet = testHeadline.slice(-10);
        return !recentHeadlines.some((rh: string) => rh.includes(tailSnippet));
      });

      const candidatePool = nonCollidingTemplates.length > 0 ? nonCollidingTemplates : pool;
      const tpl = candidatePool[Math.floor(Math.random() * candidatePool.length)];

      parsedNews = {
        headline: tpl.headline(targetStock.name),
        content: tpl.content(targetStock.name),
        sentiment: targetSentiment,
        impact_rate: tpl.impactRate,
      };
    }

    // 6. news 테이블에 인서트 (Supabase Realtime이 즉시 클라이언트로 브로드캐스트)
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