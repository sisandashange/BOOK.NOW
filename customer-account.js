(() => {
  "use strict";
  const URL = "https://pvplhsiafklaoqrpdhpd.supabase.co";
  const KEY = "sb_publishable_VKlDPkR9JvJr6E4bcz1HSg_OG5_xy5r";
  const ACCOUNT_REDIRECT_URL = "https://getbooknow.co.za/account.html";
  if (!window.supabase || !window.supabase.createClient) return;
  const db = window.supabase.createClient(URL, KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
  window.BOOKNOW_CUSTOMER_AUTH = db;
  const $ = id => document.getElementById(id);
  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const nameInitials = value => String(value || "BOOK.NOW").trim().split(/\s+/).slice(0,2).map(x=>x[0]||"").join("").toUpperCase() || "B";
  const isAccountPage = document.body.dataset.customerAccount === "true";
  let currentSession = null;
  let drawerOpen = false;
  let touchStart = null;
  let authBusy = false;

  function mountDrawer() {
    const nav = document.querySelector(".top-nav");
    if (!nav || $("customer-drawer-backdrop")) return;
    const backdrop = document.createElement("div");
    backdrop.className = "customer-drawer-backdrop";
    backdrop.id = "customer-drawer-backdrop";
    backdrop.setAttribute("aria-hidden","true");
    backdrop.innerHTML = '<nav class="customer-drawer" id="customer-drawer" aria-label="Customer navigation" aria-modal="true" role="dialog"><div class="customer-drawer-head"><div class="customer-drawer-brand">BOOK.NOW</div><button type="button" class="customer-drawer-close" aria-label="Close menu">&times;</button></div><a class="customer-drawer-account" href="account.html"><span class="customer-drawer-avatar" id="customer-drawer-avatar">B</span><span><strong id="customer-drawer-name">Sign in or create an account</strong><small id="customer-drawer-subtitle">Your bookings, all in one place</small></span></a><section><p class="customer-drawer-label">Discover</p><div class="customer-drawer-links"><a class="customer-drawer-link" href="index.html"><i class="ph ph-house"></i>Home</a><a class="customer-drawer-link" href="index.html#store-grid"><i class="ph ph-storefront"></i>Find a shop</a><a class="customer-drawer-link" href="index.html#saved-shops"><i class="ph ph-heart"></i>Saved shops</a></div></section><section><p class="customer-drawer-label">Your account</p><div class="customer-drawer-links"><a class="customer-drawer-link" href="account.html#bookings"><i class="ph ph-calendar-check"></i>My bookings & history</a><a class="customer-drawer-link" href="account.html#profile"><i class="ph ph-user-circle"></i>My profile</a><a class="customer-drawer-link" href="manage.html"><i class="ph ph-magnifying-glass"></i>Manage a guest booking</a></div></section><section><p class="customer-drawer-label">More</p><div class="customer-drawer-links"><a class="customer-drawer-link" href="privacy.html"><i class="ph ph-shield-check"></i>Privacy policy</a><a class="customer-drawer-link" href="terms.html"><i class="ph ph-file-text"></i>Terms of use</a><a class="customer-drawer-link" href="vendor.html"><i class="ph ph-storefront"></i>Partner portal</a><a class="customer-drawer-link" href="apps.html"><i class="ph ph-download-simple"></i>Get the app</a></div></section><div class="customer-drawer-footer">BOOK.NOW · Your bookings, made easier</div></nav>';
    document.body.appendChild(backdrop);
    const close = () => setDrawer(false);
    backdrop.addEventListener("click", event => { if (event.target === backdrop || event.target.closest(".customer-drawer-close")) close(); });
    backdrop.querySelectorAll("a").forEach(a => a.addEventListener("click", close));
    document.addEventListener("keydown", event => {
      if (!drawerOpen) return;
      if (event.key === "Escape") { close(); return; }
      if (event.key === "Tab") {
        const focusable = Array.from(backdrop.querySelectorAll('a[href],button:not([disabled]),[tabindex]:not([tabindex="-1"])'));
        if (!focusable.length) return;
        const first = focusable[0], last = focusable[focusable.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
      }
    });
    document.addEventListener("touchstart", event => {
      if (event.touches.length !== 1) return;
      const x = event.touches[0].clientX;
      touchStart = {x, y:event.touches[0].clientY, open:drawerOpen};
    }, {passive:true});
    document.addEventListener("touchend", event => {
      if (!touchStart || event.changedTouches.length !== 1) return;
      const dx = event.changedTouches[0].clientX - touchStart.x;
      const dy = event.changedTouches[0].clientY - touchStart.y;
      if (Math.abs(dx) > 75 && Math.abs(dx) > Math.abs(dy) * 1.25) {
        if (!touchStart.open && dx > 0) setDrawer(true);
        else if (touchStart.open && dx < 0) setDrawer(false);
      }
      touchStart = null;
    }, {passive:true});
  }

  function setDrawer(open) {
    const backdrop = $("customer-drawer-backdrop");
    if (!backdrop) return;
    drawerOpen = !!open;
    backdrop.classList.toggle("open", drawerOpen);
    backdrop.setAttribute("aria-hidden", String(!drawerOpen));
    document.body.classList.toggle("customer-drawer-open", drawerOpen);
    if (drawerOpen) backdrop.querySelector(".customer-drawer-close").focus();
  }

  function updateDrawer(session, profile) {
    const name = profile?.full_name || session?.user?.user_metadata?.full_name || session?.user?.email || "";
    const n = $("customer-drawer-name"), sub = $("customer-drawer-subtitle"), avatar = $("customer-drawer-avatar");
    if (!n || !sub || !avatar) return;
    n.textContent = session ? (name || "My account") : "Sign in or create an account";
    sub.textContent = session ? (session.user.email || "Customer account") : "Your bookings, all in one place";
    avatar.textContent = nameInitials(name);
  }

  async function getProfile(userId) {
    const {data,error} = await db.from("customer_profiles").select("id,full_name,phone,avatar_url").eq("id",userId).maybeSingle();
    if (error) throw error;
    return data;
  }

  async function accountPageInit() {
    const authCard = $("customer-auth-card");
    if (!authCard) return;
    const setMessage = (message, kind="") => { const el=$("account-auth-message"); el.textContent=message; el.className="account-message"+(kind?" "+kind:""); };
    const setBusy = busy => { authBusy=busy; document.querySelectorAll("[data-auth-submit]").forEach(b=>{b.disabled=busy;b.textContent=busy?(b.dataset.busyText||"Please wait…"):(b.dataset.idleText||b.textContent);}); };
    const showSignedOut = () => {
      $("customer-auth-card").hidden=false; $("customer-account-content").hidden=true;
      updateDrawer(null,null);
    };
    function showAccountSection(section, updateHash=true) {
      const allowed = ["bookings", "profile", "link-booking"];
      const selected = allowed.includes(section) ? section : "bookings";
      document.querySelectorAll("[data-account-section]").forEach(el => {
        el.hidden = el.dataset.accountSection !== selected;
      });
      document.querySelectorAll("[data-account-nav]").forEach(link => {
        const active = link.dataset.accountNav === selected;
        link.classList.toggle("active", active);
        if (active) link.setAttribute("aria-current", "page");
        else link.removeAttribute("aria-current");
      });
      const message = $("account-section-message");
      if (message) message.textContent = selected === "bookings" ? "Your booking history" : selected === "profile" ? "Your personal account details" : "Connect a previous guest booking to your account";
      if (updateHash && location.hash !== "#" + selected) history.replaceState(null, "", "#" + selected);
    }
    function syncAccountSection() {
      showAccountSection(location.hash.slice(1) || "bookings", false);
    }
    document.querySelectorAll("[data-account-nav]").forEach(link => {
      link.addEventListener("click", event => {
        event.preventDefault();
        showAccountSection(link.dataset.accountNav, true);
      });
    });
    window.addEventListener("hashchange", syncAccountSection);
    async function renderBookings() {
      const list=$("customer-booking-list");
      list.innerHTML='<div class="account-empty">Loading your bookings…</div>';
      const {data,error}=await db.rpc("list_my_customer_bookings");
      if(error) throw error;
      if(!Array.isArray(data)||!data.length){list.innerHTML='<div class="account-empty">No bookings are linked to this account yet.<br>You can still book as a guest, or link an earlier booking below.</div>';return;}
      list.replaceChildren();
      data.forEach(b=>{
        const item=document.createElement("article"); item.className="account-booking";
        const top=document.createElement("div"); top.className="account-booking-top";
        const title=document.createElement("h3"); title.textContent=b.store_name||"BOOK.NOW shop";
        const badge=document.createElement("span"); badge.className="account-status "+String(b.status||"").toLowerCase(); badge.textContent=b.status||"Pending";
        top.append(title,badge); item.append(top);
        const line1=document.createElement("p"); line1.textContent=(b.service_title|| (b.is_takeaway?"Takeaway order":"Booking"))+" · "+(b.booking_date||"")+" · "+(b.booking_time||"");
        const line2=document.createElement("p"); line2.textContent="Reference: "+(b.payment_ref||"")+" · "+(b.payment_status||"UNPAID")+" · R"+Number(b.booked_price||0).toFixed(2);
        item.append(line1,line2); list.appendChild(item);
      });
    }
    async function showSignedIn(session) {
      currentSession=session;
      $("customer-auth-card").hidden=true; $("customer-account-content").hidden=false;
      syncAccountSection();
      const user=session.user;
      let profile=await getProfile(user.id);
      if(!profile){
        const {error}=await db.from("customer_profiles").upsert({id:user.id,full_name:user.user_metadata?.full_name||"",phone:""});
        if(error) throw error;
        profile=await getProfile(user.id);
      }
      $("profile-name").value=profile?.full_name||"";
      $("profile-phone").value=profile?.phone||"";
      $("profile-email").value=user.email||"";
      updateDrawer(session,profile);
      await renderBookings();
    }
    document.querySelectorAll("[data-auth-tab]").forEach(btn=>btn.addEventListener("click",()=>{
      document.querySelectorAll("[data-auth-tab]").forEach(x=>x.classList.toggle("active",x===btn));
      const signup=btn.dataset.authTab==="signup";
      $("signup-name-wrap").hidden=!signup;
      $("auth-submit").textContent=signup?"Create account":"Sign in";
      $("auth-submit").dataset.idleText=signup?"Create account":"Sign in";
      $("auth-forgot").hidden=signup;
      setMessage("");
    }));
    $("customer-auth-form").addEventListener("submit",async event=>{
      event.preventDefault(); if(authBusy)return;
      const signup=document.querySelector('[data-auth-tab].active')?.dataset.authTab==="signup";
      const email=$("auth-email").value.trim().toLowerCase(), password=$("auth-password").value;
      if(!email||!password){setMessage("Enter your email and password.","error");return;}
      setBusy(true);
      try{
        if(signup){
          const fullName=$("auth-full-name").value.trim();
          if(fullName.length<2)throw new Error("Enter your name so your profile can be created.");
          if(password.length<8)throw new Error("Use a password with at least 8 characters.");
          const {data,error}=await db.auth.signUp({email,password,options:{emailRedirectTo:ACCOUNT_REDIRECT_URL,data:{full_name:fullName}}});
          if(error)throw error;
          if(data.session){await showSignedIn(data.session);setMessage("Your account is ready.","success");}
          else setMessage("Check your email for the confirmation link. You can keep booking as a guest while you wait.","success");
        }else{
          const {data,error}=await db.auth.signInWithPassword({email,password});
          if(error)throw error;
          await showSignedIn(data.session);
          setMessage("");
        }
      }catch(error){setMessage(error.message||"We couldn't complete that request. Please try again.","error");}
      finally{setBusy(false);}
    });
    const recoveryForm = $("customer-password-reset-form");
    const recoveryPending = /(?:^|[&#])type=recovery(?:&|$)/.test(location.hash);
    if (recoveryPending && recoveryForm) {
      recoveryForm.hidden=false;
      $("customer-auth-card").hidden=false;
      $("customer-account-content").hidden=true;
      setMessage("Choose a new password to finish resetting your account.","success");
    }
    if (recoveryForm) recoveryForm.addEventListener("submit",async event=>{
      event.preventDefault();
      const password=$("reset-new-password").value;
      if(password.length<8){$("reset-message").textContent="Use a password with at least 8 characters.";return;}
      setBusy(true);
      try{const {error}=await db.auth.updateUser({password});if(error)throw error;recoveryForm.hidden=true;$("reset-message").textContent="Your password has been updated. You can continue using BOOK.NOW.";setMessage("Password updated.","success");}
      catch(error){$("reset-message").textContent=error.message||"Password could not be updated.";}
      finally{setBusy(false);}
    });

    $("auth-forgot").addEventListener("click",async()=>{
      const email=$("auth-email").value.trim().toLowerCase();
      if(!email){setMessage("Enter your email address first.");return;}
      setBusy(true);
      try{const {error}=await db.auth.resetPasswordForEmail(email,{redirectTo:ACCOUNT_REDIRECT_URL});if(error)throw error;setMessage("If that email belongs to an account, a password reset link has been sent.","success");}
      catch(error){setMessage(error.message||"We couldn't send the reset email.","error");}
      finally{setBusy(false);}
    });
    $("customer-profile-form").addEventListener("submit",async event=>{
      event.preventDefault();if(authBusy||!currentSession)return;
      const full_name=$("profile-name").value.trim(),phone=$("profile-phone").value.trim();
      if(full_name.length<2){$("profile-message").textContent="Enter your full name.";return;}
      if(phone && !/^[+0-9()\s-]{9,20}$/.test(phone)){$("profile-message").textContent="Check your phone number.";return;}
      setBusy(true);
      try{
        const {error}=await db.from("customer_profiles").update({full_name,phone,updated_at:new Date().toISOString()}).eq("id",currentSession.user.id);
        if(error)throw error;
        updateDrawer(currentSession,{full_name});
        $("profile-message").textContent="Profile saved.";
      }catch(error){$("profile-message").textContent=error.message||"Profile could not be saved.";}
      finally{setBusy(false);}
    });
    $("customer-claim-form").addEventListener("submit",async event=>{
      event.preventDefault();if(authBusy||!currentSession)return;
      const p_ref=$("claim-ref").value.trim().toUpperCase(),p_phone=$("claim-phone").value.trim();
      if(!p_ref||!p_phone){$("claim-message").textContent="Enter the booking reference and the phone number used for that booking.";return;}
      setBusy(true);
      try{
        const {data,error}=await db.rpc("claim_customer_booking",{p_ref,p_phone});
        if(error)throw error;
        if(!data?.success)throw new Error(data?.message||"We couldn't verify that booking. Check the reference and phone number.");
        $("claim-ref").value="";$("claim-phone").value="";
        $("claim-message").textContent="Booking linked to your account.";
        await renderBookings();
      }catch(error){$("claim-message").textContent=error.message||"We couldn't link that booking.";}
      finally{setBusy(false);}
    });
    $("customer-signout").addEventListener("click",async()=>{
      const {error}=await db.auth.signOut();
      if(error){$("profile-message").textContent=error.message;return;}
      currentSession=null;showSignedOut();setMessage("You have signed out.");
    });
    const {data:{session},error}=await db.auth.getSession();
    if(error)throw error;
    currentSession=session;
    if(session && !recoveryPending){await showSignedIn(session);}else if(!recoveryPending)showSignedOut();
    db.auth.onAuthStateChange((event,session)=>{
      currentSession=session;
      if(event==="PASSWORD_RECOVERY" && recoveryForm){
        recoveryForm.hidden=false;
        $("customer-auth-card").hidden=false;
        $("customer-account-content").hidden=true;
        $("reset-new-password").focus();
        return;
      }
      if(!session){showSignedOut();return;}
      // Avoid awaiting Supabase calls inside the auth callback; render on the next task.
      Promise.resolve().then(()=>showSignedIn(session)).catch(error=>setMessage(error.message||"Account could not be loaded.","error"));
    });
    if(new URLSearchParams(location.search).has("code"))setMessage("Finishing your secure sign-in…");
  }

  async function init(){
    mountDrawer();
    const {data:{session}}=await db.auth.getSession();
    currentSession=session;
    updateDrawer(session,null);
    if(session){try{const profile=await getProfile(session.user.id);window.BOOKNOW_CUSTOMER_PROFILE=profile;updateDrawer(session,profile);window.dispatchEvent(new CustomEvent("booknow:customer-ready",{detail:{session,profile}}));}catch(_){}}
    db.auth.onAuthStateChange((_event,session)=>{currentSession=session;updateDrawer(session,null);if(session)getProfile(session.user.id).then(p=>{window.BOOKNOW_CUSTOMER_PROFILE=p;updateDrawer(session,p);window.dispatchEvent(new CustomEvent("booknow:customer-ready",{detail:{session,profile:p}}));}).catch(()=>{});else{window.BOOKNOW_CUSTOMER_PROFILE=null;window.dispatchEvent(new CustomEvent("booknow:customer-ready",{detail:{session:null,profile:null}}));}});
    if(isAccountPage)await accountPageInit();
  }
  init().catch(error=>{console.error("BOOK.NOW customer account init failed",error);const el=$("account-auth-message");if(el)el.textContent="Account services are temporarily unavailable. Guest booking is still available.";});
})();