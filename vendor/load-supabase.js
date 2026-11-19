/* Načte knihovnu Supabase jen v ostrém provozu (když je vyplněný config.js). */
if(window.RG_CFG&&RG_CFG.supabaseUrl&&RG_CFG.supabaseKey)document.write('<script src="vendor/supabase.js"><\/script>');
