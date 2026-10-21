//+------------------------------------------------------------------+
//| TwsiatPriceBridge.mq5                                            |
//| Sends closed M5 bars + live prices to the Twsiat database.       |
//| Read-only: it never opens, changes or closes any trade.          |
//|                                                                  |
//| Setup:                                                           |
//|  1. Tools > Options > Expert Advisors > tick "Allow WebRequest    |
//|     for listed URL" and add:  https://iqkuyqvhsrzlnanltybu.supabase.co
//|  2. Put the token on the BridgeToken line, compile, attach to     |
//|     ANY one chart. One copy is enough for all symbols.           |
//|  3. Leave MT5 running (VPS).                                     |
//+------------------------------------------------------------------+
#property description "Twsiat price bridge — sends M5 bars and live prices, never trades"
#property version     "2.1"

input string SupabaseUrl    = "https://iqkuyqvhsrzlnanltybu.supabase.co";
input string PublishableKey = "sb_publishable_bFGGkLFIOZYIfjbMrogW7g_Haw2W0zt";
input string BridgeToken    = "";                 // from Supabase (app_secrets 'bridge_token') — never share it
input string Symbols        = "XAUUSD,XAGUSD,USOIL,UKOIL,XNGUSD,US30,USTEC,US500,DE30,UK100,JP225,EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,USDCAD,NZDUSD,BTCUSD,ETHUSD";
input string ExtraSymbols1  = "EURGBP,EURAUD,EURNZD,EURCAD,EURCHF,EURJPY,GBPAUD,GBPNZD,GBPCAD,GBPCHF,GBPJPY,AUDNZD,AUDCAD,AUDCHF,AUDJPY,NZDCAD,NZDCHF,NZDJPY,CADCHF,CADJPY,CHFJPY";  // alerts app
input string ExtraSymbols2  = "XPTUSD,XPDUSD,XCUUSD,FR40,STOXX50,AUS200,HK50,DXY,XRPUSD,SOLUSD,UNIUSD,MSFT,NVDA,AMD,AMZN,NFLX";  // alerts app
input string BrokerSuffix   = "m";                // Exness Standard account: XAUUSD -> XAUUSDm
input int    BackfillDays   = 120;                // history sent once per symbol (indicators need ~60 days)
input int    ServerGmtOffsetHours = 0;            // Exness = 0. If your server is GMT+2, put 2.
input int    PushEverySeconds = 30;               // closed M5 bars
input int    LiveEverySeconds = 5;                // live prices for the alerts app (0 = off)

int      g_ticks = 0;
datetime g_live_last[];
string   g_broker[];
string   g_name[];
datetime g_last_sent[];
bool     g_backfilled[];

int OnInit()
{
   if(StringLen(BridgeToken) < 10) { Alert("TwsiatPriceBridge: BridgeToken is empty"); return INIT_PARAMETERS_INCORRECT; }
   string list[];
   string all = Symbols;
   if(StringLen(ExtraSymbols1) > 0) all += "," + ExtraSymbols1;
   if(StringLen(ExtraSymbols2) > 0) all += "," + ExtraSymbols2;
   int n = StringSplit(all, ',', list);
   ArrayResize(g_broker, 0); ArrayResize(g_name, 0); ArrayResize(g_last_sent, 0); ArrayResize(g_backfilled, 0); ArrayResize(g_live_last, 0);
   for(int i = 0; i < n; i++)
   {
      string name = list[i];
      StringTrimLeft(name); StringTrimRight(name);
      if(name == "") continue;
      string broker = name + BrokerSuffix;
      if(!SymbolSelect(broker, true)) { Print("TwsiatPriceBridge: symbol not found at this broker, skipped: ", broker); continue; }
      int k = ArraySize(g_broker);
      ArrayResize(g_broker, k + 1); ArrayResize(g_name, k + 1); ArrayResize(g_last_sent, k + 1); ArrayResize(g_backfilled, k + 1); ArrayResize(g_live_last, k + 1);
      g_broker[k] = broker; g_name[k] = name; g_last_sent[k] = 0; g_backfilled[k] = false; g_live_last[k] = 0;
   }
   if(ArraySize(g_broker) == 0) { Alert("TwsiatPriceBridge: no valid symbols"); return INIT_PARAMETERS_INCORRECT; }
   // one timer: live prices every LiveEverySeconds, closed bars every PushEverySeconds
   EventSetTimer(LiveEverySeconds > 0 ? (int)MathMin(LiveEverySeconds, PushEverySeconds) : PushEverySeconds);
   Print("TwsiatPriceBridge 2.1 started for ", ArraySize(g_broker), " symbols; live prices every ", LiveEverySeconds, "s");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
{
   int step = (LiveEverySeconds > 0 ? (int)MathMin(LiveEverySeconds, PushEverySeconds) : PushEverySeconds);
   if(LiveEverySeconds > 0) SendLive();
   g_ticks += step;
   if(g_ticks < PushEverySeconds) return;
   g_ticks = 0;

   // 1) bars: resend the last hour of closed bars for every symbol already backfilled (upsert makes it safe)
   for(int i = 0; i < ArraySize(g_broker); i++)
      if(g_backfilled[i])
         SendRange(i, g_last_sent[i] > 0 ? g_last_sent[i] - 3600 : TimeCurrent() - 86400, 500);

   // 2) history: one symbol per cycle, so MT5 never freezes
   for(int i = 0; i < ArraySize(g_broker); i++)
      if(!g_backfilled[i])
      {
         if(SendRange(i, TimeCurrent() - BackfillDays * 86400, 1000))
         {
            g_backfilled[i] = true;
            Print("TwsiatPriceBridge: history sent for ", g_name[i]);
         }
         break;
      }
}

// Send closed M5 bars from 'from' to now, in chunks. Returns false if nothing could be sent.
bool SendRange(int idx, datetime from, int chunk)
{
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(g_broker[idx], PERIOD_M5, from, TimeCurrent(), r);
   if(got <= 1) return false;                  // history still loading at the terminal: try next cycle
   int closed = got - 1;                       // last bar is still forming: skip it
   double pt = SymbolInfoDouble(g_broker[idx], SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(g_broker[idx], SYMBOL_DIGITS);
   for(int s = 0; s < closed; s += chunk)
   {
      int e = MathMin(s + chunk, closed);
      string bars = "";
      for(int k = s; k < e; k++)
      {
         datetime tg = r[k].time - ServerGmtOffsetHours * 3600;
         if(k > s) bars += ",";
         bars += StringFormat("{\"t\":\"%s\",\"o\":%s,\"h\":%s,\"l\":%s,\"c\":%s,\"s\":%s}",
                              TimeToString(tg, TIME_DATE | TIME_MINUTES),
                              DoubleToString(r[k].open, digits), DoubleToString(r[k].high, digits),
                              DoubleToString(r[k].low, digits), DoubleToString(r[k].close, digits),
                              DoubleToString(r[k].spread * pt, digits));
      }
      string body = StringFormat("{\"p_token\":\"%s\",\"p_symbol\":\"%s\",\"p_bars\":[%s]}", BridgeToken, g_name[idx], bars);
      if(!Post(body)) return false;
      g_last_sent[idx] = r[e - 1].time;
   }
   return true;
}

// Live prices: the current bid of every symbol whose price changed, in one request.
void SendLive()
{
   string quotes = "";
   for(int i = 0; i < ArraySize(g_broker); i++)
   {
      MqlTick tk;
      if(!SymbolInfoTick(g_broker[i], tk) || tk.bid <= 0) continue;
      if(tk.time == g_live_last[i]) continue;          // nothing new (market closed)
      int digits = (int)SymbolInfoInteger(g_broker[i], SYMBOL_DIGITS);
      datetime tg = tk.time - ServerGmtOffsetHours * 3600;
      if(quotes != "") quotes += ",";
      quotes += StringFormat("{\"s\":\"%s\",\"b\":%s,\"t\":\"%s\"}", g_name[i],
                             DoubleToString(tk.bid, digits), TimeToString(tg, TIME_DATE | TIME_SECONDS));
      g_live_last[i] = tk.time;
   }
   if(quotes == "") return;
   string body = StringFormat("{\"p_token\":\"%s\",\"p_quotes\":[%s]}", BridgeToken, quotes);
   if(!Post(body, "ingest_live"))
      ArrayInitialize(g_live_last, 0);                  // failed: send everything again next time
}

bool Post(string body, string fn = "ingest_prices")
{
   string url = SupabaseUrl + "/rest/v1/rpc/" + fn;
   string headers = "Content-Type: application/json\r\napikey: " + PublishableKey + "\r\nAuthorization: Bearer " + PublishableKey + "\r\n";
   char data[], result[];
   string result_headers;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;   // drop trailing 0
   ArrayResize(data, len);
   ResetLastError();
   int code = WebRequest("POST", url, headers, 20000, data, result, result_headers);
   if(code == -1)
   {
      Print("TwsiatPriceBridge: WebRequest failed, error ", GetLastError(),
            " — add ", SupabaseUrl, " under Tools > Options > Expert Advisors > Allow WebRequest");
      return false;
   }
   if(code != 200)
   {
      Print("TwsiatPriceBridge: HTTP ", code, " ", CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
      return false;
   }
   return true;
}
