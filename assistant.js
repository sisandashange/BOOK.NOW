/* BOOK.NOW Help — local, curated FAQ assistant. No external AI/API calls. */
(() => {
  "use strict";
  const CONTACT = {
    email: "mfanarhshange43@gmail.com",
    phone: "075 297 8917",
    whatsapp: "https://wa.me/27813705158"
  };
  const FAQ = [
    {q:"Do I need to download an app or create an account?", keys:["app","download","account","sign up","register","guest","without account"], a:"No. You can browse shops and make a booking as a guest on the BOOK.NOW website. A customer account is optional."},
    {q:"How do I find a shop?", keys:["find","search","shop","salon","barber","shisanyama","braai","near","area","location"], a:"Open the BOOK.NOW home page, search by shop name, service or category, and use the category and area filters when available. Select a shop to view its details and booking options."},
    {q:"How do I make a booking?", keys:["book","booking","appointment","reserve","reservation","choose time","make"], a:"Find the shop you want, open its page, choose an available service or booking option, select an available date and time, then follow the booking steps. Enter a correct name and phone number so the shop can contact you."},
    {q:"Can I see prices and opening hours?", keys:["price","cost","fee","opening","hours","open","close","service"], a:"Shop owners set their own services, prices and opening hours. Check the shop page for the latest details. Contact the shop directly if you need confirmation."},
    {q:"How do I pay for my booking?", keys:["pay","payment","eft","cash","bank","reference","payfast","card"], a:"You pay the shop directly by EFT or cash, using the unique payment reference shown on your booking. BOOK.NOW does not receive or hold customer booking payments. Follow the payment instructions shown for that shop."},
    {q:"How do I cancel or change a booking?", keys:["cancel","change","reschedule","edit","move","appointment"], a:"Use the “Manage my booking” link on the home page. You can cancel or change a booking until 2 hours before the appointment. If you already paid, agree any refund directly with the shop."},
    {q:"Where is my booking receipt or reference?", keys:["receipt","reference","confirmation","booking number","proof","qr","ticket"], a:"Keep the booking confirmation and its unique payment reference. If you need to manage the booking, open “Manage my booking” from the home page and follow the verification steps."},
    {q:"Who handles refunds?", keys:["refund","money back","paid already","repay"], a:"Refunds for money already paid are agreed directly between you and the shop. BOOK.NOW does not receive or hold your booking payment."},
    {q:"Can I save my favourite shops?", keys:["favourite","favorite","save","heart","saved"], a:"Yes. You can save favourite shops on the same device without an account. If you sign in to your optional customer account, your saved shops can sync across devices."},
    {q:"How do shisanyama bookings work?", keys:["shisanyama","seats","table","people","guests","braai"], a:"Shisanyama shops can offer bookings based on available seating and the number of people. Choose the option and guest count shown by that shop. Availability is controlled by the business."},
    {q:"How do I contact BOOK.NOW support?", keys:["support","help","contact","problem","issue","complaint","talk","human"], a:"You can email mfanarhshange43@gmail.com, call 075 297 8917, or WhatsApp 081 370 5158. For a shop-specific service, price or refund question, contact the shop directly."}
  ];
  const QUICK = ["How do I make a booking?","How do I pay?","Cancel or change a booking","I need support"];
  const normalize = value => String(value || "").toLowerCase().replace(/[^a-z0-9\\s]/g, " ").replace(/\\s+/g, " ").trim();
  function findAnswer(message) {
    const text = normalize(message);
    if (!text) return null;
    let best = null, score = 0;
    for (const item of FAQ) {
      let current = 0;
      for (const key of item.keys) {
        const term = normalize(key);
        if (text.includes(term)) current += term.includes(" ") ? 3 : 2;
      }
      for (const word of text.split(" ")) {
        if (word.length > 3 && item.q.toLowerCase().includes(word)) current += 1;
      }
      if (current > score) { score = current; best = item; }
    }
    return score >= 2 ? best : null;
  }
  function init() {
    if (document.getElementById("bn-help-launcher")) return;
    const launcher = document.createElement("button");
    launcher.id = "bn-help-launcher"; launcher.type = "button";
    launcher.className = "bn-help-launcher"; launcher.setAttribute("aria-label", "Ask BOOK.NOW for help");
    launcher.innerHTML = '<span aria-hidden="true">✦</span> Ask BOOK.NOW';
    const panel = document.createElement("section");
    panel.id = "bn-help-panel"; panel.className = "bn-help-panel"; panel.hidden = true;
    panel.setAttribute("role","dialog"); panel.setAttribute("aria-modal","false"); panel.setAttribute("aria-labelledby","bn-help-title");
    panel.innerHTML = '<header class="bn-help-head"><div><strong id="bn-help-title">BOOK.NOW Help</strong><small>Questions about using BOOK.NOW</small></div><button type="button" class="bn-help-close" aria-label="Close help">×</button></header><div class="bn-help-note">I use BOOK.NOW’s help guide. I do not access your private bookings or payment records.</div><div class="bn-help-messages" id="bn-help-messages" aria-live="polite"><div class="bn-help-bubble bot">Hi! 👋 What would you like help with?</div><div class="bn-help-quick" id="bn-help-quick"></div></div><form class="bn-help-form" id="bn-help-form"><input id="bn-help-input" type="text" maxlength="300" autocomplete="off" placeholder="Ask a BOOK.NOW question…" aria-label="Your question" required><button type="submit" aria-label="Send question">Send</button></form><div class="bn-help-support">Need a person? <a href="https://wa.me/27813705158" target="_blank" rel="noopener">WhatsApp support</a></div>';
    document.body.append(launcher,panel);
    const messages=panel.querySelector("#bn-help-messages"), quick=panel.querySelector("#bn-help-quick"), form=panel.querySelector("#bn-help-form"), input=panel.querySelector("#bn-help-input");
    function addBubble(text, who) { const node=document.createElement("div"); node.className="bn-help-bubble "+who; node.textContent=text; messages.insertBefore(node,quick); messages.scrollTop=messages.scrollHeight; }
    function answer(question) {
      addBubble(question,"user");
      if (/\\b(support|human|person|someone)\\b/i.test(question)) {
        addBubble("Of course. Email "+CONTACT.email+", call "+CONTACT.phone+", or contact support on WhatsApp. For a question about a specific shop’s service or refund, contact that shop directly.","bot");
      } else {
        const match=findAnswer(question);
        addBubble(match ? match.a : "I’m not sure about that, and I don’t want to guess. Please try asking about finding a shop, making or managing a booking, payments, or contact BOOK.NOW support on WhatsApp.","bot");
      }
      messages.scrollTop=messages.scrollHeight;
    }
    QUICK.forEach(label=>{const b=document.createElement("button");b.type="button";b.textContent=label;b.addEventListener("click",()=>answer(label));quick.append(b);});
    launcher.addEventListener("click",()=>{panel.hidden=false;launcher.hidden=true;input.focus();});
    panel.querySelector(".bn-help-close").addEventListener("click",()=>{panel.hidden=true;launcher.hidden=false;launcher.focus();});
    form.addEventListener("submit",event=>{event.preventDefault();const value=input.value.trim();if(!value)return;input.value="";answer(value);});
    document.addEventListener("keydown",event=>{if(event.key==="Escape"&&!panel.hidden){panel.hidden=true;launcher.hidden=false;}});
  }
  if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",init,{once:true}); else init();
})();