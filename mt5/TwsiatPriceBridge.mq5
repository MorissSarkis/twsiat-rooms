//+------------------------------------------------------------------+
//| TwsiatPriceBridge.mq5                                            |
//| Sends closed M5 bars to the Twsiat Rooms database (Supabase).    |
//| Read-only: it never opens, changes or closes any trade.          |
//|                                                                  |
//| Setup:                                                           |
//|  1. Tools > Options > Expert Advisors > tick "Allow WebRequest    |
//|     for listed URL" and add:  https://iqkuyqvhsrzlnanltybu.supabase.co
//|  2. Attach to ANY chart (one copy is enough), fill BridgeToken.   |
//|  3. Leave MT5 running (VPS).                                     |
//+------------------------------------------------------------------+
#property description "Twsiat Rooms price bridge — sends M5 bars, never trades"

input string SupabaseUrl    = "https://iqkuyqvhsrzlnanltybu.supabase.co";
input string PublishableKey = "sb_publishable_bFGGkLFIOZYIfjbMrogW7g_Haw2W0zt";
input string BridgeToken    = "";                 // from db/005_schedule.sql
input string SymbolMap      = "XAUUSDm=XAUUSD";   // broker symbol = name in the platform; comma separated
input int    BackfillDays   = 150;                // history sent once at start (indicators need ~90 days)
input int    ServerGmtOffsetHours = 0;            // Exness = 0. If your server is GMT+2, put 2.
input int    PushEverySeconds = 30;

string g_broker[];
string g_name[];
datetime g_last_sent[];

int OnInit()
{
   if(StringLen(BridgeToken) < 10) { Alert("TwsiatPriceBridge: BridgeToken is empty"); return INIT_PARAMETERS_INCORRECT; }
   string pairs[];
   int n = StringSplit(SymbolMap, ',', pairs);
   ArrayResize(g_broker, n); ArrayResize(g_name, n); ArrayResize(g_last_sent, n);
   for(int i = 0; i < n; i++)
   {
      string kv[];
      StringTrimLeft(pairs[i]); StringTrimRight(pairs[i]);
      if(StringSplit(pairs[i], '=', kv) != 2) { Alert("Bad SymbolMap entry: ", pairs[i]); return INIT_PARAMETERS_INCORRECT; }
      g_broker[i] = kv[0]; g_name[i] = kv[1]; g_last_sent[i] = 0;
      SymbolSelect(g_broker[i], true);
   }
   // backfill history once
   for(int i = 0; i < n; i++)
      SendRange(i, TimeCurrent() - BackfillDays * 86400, 1000);
   EventSetTimer(PushEverySeconds);
   Print("TwsiatPriceBridge started for ", SymbolMap);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
{
   for(int i = 0; i < ArraySize(g_broker); i++)
   {
      // resend the last hour of closed bars each time (cheap; upsert makes it safe)
      datetime from = (g_last_sent[i] > 0) ? g_last_sent[i] - 3600 : TimeCurrent() - 86400;
      SendRange(i, from, 500);
   }
}

// Send closed M5 bars from 'from' to now, in chunks.
void SendRange(int idx, datetime from, int chunk)
{
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = -1;
   for(int a = 0; a < 5 && got <= 0; a++) { got = CopyRates(g_broker[idx], PERIOD_M5, from, TimeCurrent(), r); if(got <= 0) Sleep(1000); }
   if(got <= 1) return;
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
      if(Post(body)) g_last_sent[idx] = r[e - 1].time;
      else return;
   }
}

bool Post(string body)
{
   string url = SupabaseUrl + "/rest/v1/rpc/ingest_prices";
   string headers = "Content-Type: application/json\r\napikey: " + PublishableKey + "\r\nAuthorization: Bearer " + PublishableKey + "\r\n";
   char data[], result[];
   string result_headers;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;   // drop trailing 0
   ArrayResize(data, len);
   ResetLastError();
   int code = WebRequest("POST", url, headers, 10000, data, result, result_headers);
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
