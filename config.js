/* =====================================================================
   RunGame – nastavení webu
   Dokud jsou supabaseUrl a supabaseKey prázdné, web běží jako UKÁZKA
   (data jen v prohlížeči, testovací účty). Po vyplnění jede OSTRÝ PROVOZ.
   ===================================================================== */
window.RG_CFG = {
  // Supabase → Project Settings → API (Data API): Project URL
  supabaseUrl: "https://setgezrfsfmkfxymrarr.supabase.co",
  // Supabase → Project Settings → API Keys: "anon public" (nebo "publishable") klíč. Je veřejný, smí být tady.
  supabaseKey: "sb_publishable_jmrUFnF0BmJ9Q0t3mqBiKw_SvisPfN4",
  // Účet pro platby startovného (QR platba). Formát: "123456789/5500" nebo "19-123456789/5500".
  bank: { account: "", name: "RunGame" }
};
