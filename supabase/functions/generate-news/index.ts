import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OLLAMA_HOST = Deno.env.get("OLLAMA_HOST") || "http://host.docker.internal:11434";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // 1. 임의의 상장 종목 1건 조회
    const { data: stocks, error: stockError } = await supabase
      .from("stocks")
      .select("id, name, current_price")
      .eq("status", "LISTED");

    if (stockError || !stocks || stocks.length === 0) {
      return new Response(JSON.stringify({ error: "No active stocks found" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const targetStock = stocks[Math.floor(Math.random() * stocks.length)];

    // 2. Ollama에 가상 뉴스 생성 요청 (qwen2.5-coder:7b)
    const prompt = `[학급 모의투자 시황 뉴스 생성]
종목명: ${targetStock.name}
현재가: ${targetStock.current_price}원
위 종목에 대해 학생 모의투자 시장에서 발생할 법한 흥미로운 가상의 호재 또는 악재 뉴스 기사를 한국어로 작성해줘.
반드시 아래 JSON 형식으로만 응답해:
{
  "headline": "[속보/특징주] 뉴스 헤드라인",
  "content": "2문장 이내의 상세 기사 내용",
  "sentiment": "POSITIVE 또는 NEGATIVE",
  "impact_rate": 3.5
}`;

    let parsedNews;
    try {
      const ollamaRes = await fetch(`${OLLAMA_HOST}/api/generate`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: "qwen2.5-coder:7b",
          prompt: prompt,
          format: "json",
          stream: false,
        }),
      });

      const ollamaData = await ollamaRes.json();
      parsedNews = JSON.parse(ollamaData.response);
    } catch (llmErr) {
      // Ollama 호출 실패 시 기본 템플릿 뉴스 대체 (Fallback)
      parsedNews = {
        headline: `[특징주] ${targetStock.name}, 학급 내 수요 급증으로 시장 관심 집중`,
        content: `${targetStock.name}에 대한 학생들의 거래 참여가 활발해지며 변동성이 확대되고 있습니다. 투자에 유의가 필요합니다.`,
        sentiment: "POSITIVE",
        impact_rate: 2.5,
      };
    }

    // 3. news 테이블에 등록
    const { data: insertedNews, error: insertError } = await supabase
      .from("news")
      .insert({
        stock_id: targetStock.id,
        headline: parsedNews.headline,
        content: parsedNews.content,
        sentiment: parsedNews.sentiment || "NEUTRAL",
        impact_rate: parsedNews.impact_rate || 0.0,
      })
      .select()
      .single();

    if (insertError) {
      throw insertError;
    }

    return new Response(JSON.stringify({ success: true, news: insertedNews }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
