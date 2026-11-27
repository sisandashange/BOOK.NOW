/* BOOK.NOW Help — curated, product-specific answers. No external AI/API calls. */
(() => {
  "use strict";
  const CONTACT = {
    email: "mfanarhshange43@gmail.com",
    phone: "075 297 8917",
    whatsapp: "https://wa.me/27813705158"
  };
  const FAQ = [
    {q:"Do I need an app or an account?",keys:["app","download","account","sign up","register","guest","without account"],a:"No. You can browse shops and make bookings as a guest on the BOOK.NOW website. A customer account is optional."},
    {q:"How do I find a shop?",keys:["find","search","shop","salon","barber","shisanyama","braai","area","location","category","filter"],a:"On the home page, search by shop name, service or category. You can also filter by shop type and area, and sort the available results. Open a shop to see its services and booking options."},
    {q:"How do I make a booking?",keys:["book","booking","appointment","reserve","reservation","choose time","make"],a:"Open the shop you want, choose a listed service or booking option, select an available date and time, enter your details and follow the confirmation steps. Use a phone number the shop can reach you on."},
    {q:"Why can't I see a time or date?",keys:["no times","no time","not available","availability","fully booked","date unavailable","closed","no slots","time missing"],a:"The shop controls its opening hours, closure dates and booking capacity. A date may be closed or all its available slots may be full. Try another date or time, or contact the shop to ask."},
    {q:"Where can I see prices and opening hours?",keys:["price","prices","cost","fee","opening","hours","open","close","service menu"],a:"Each business sets its own services, menu items, prices and opening hours. Open the shop page and check its details. Contact the shop directly if anything is unclear."},
    {q:"How do I pay?",keys:["pay","payment","eft","cash","bank","reference","payfast","card","money"],a:"Choose one of the payment methods offered by the shop: EFT or cash. For EFT, use the shop's bank details and the unique payment reference shown on your booking. You pay the business directly; BOOK.NOW does not receive or hold customer booking payments."},
    {q:"How do I cancel or change my booking?",keys:["cancel","change","reschedule","edit","move","appointment"],a:"Open the Manage booking page. Enter the payment reference from your booking receipt and the same phone number you used when booking. You can change the date or time, or cancel, until 2 hours before the appointment. After that, contact the shop."},
    {q:"How do I manage a guest booking?",keys:["manage booking","guest booking","booking lookup","find my booking","booking reference","reference and phone"],a:"Open Manage booking from the BOOK.NOW menu. Enter the payment reference on your receipt and the phone number used for that booking. This verifies the booking so you can view its details and available actions."},
    {q:"Where is my receipt and QR code?",keys:["receipt","qr","qr code","ticket","confirmation","proof of booking"],a:"Your receipt stays in BOOK.NOW. Open Manage booking using your payment reference and booking phone number to view it. Show the QR code on your phone when you arrive; the shop can scan it to find your booking. The QR closes automatically after the booking is completed or cancelled."},
    {q:"What if I paid already and need a refund?",keys:["refund","money back","paid already","repay","return payment"],a:"BOOK.NOW does not receive or hold your booking payment. If you paid the shop directly, contact that shop to discuss a refund. The shop handles refunds for payments it received."},
    {q:"How do customer accounts work?",keys:["create account","sign in","login","log in","password","my account","booking history","forgot password"],a:"A customer account is optional. You can create one with your name, email and password to see bookings made while signed in, manage your profile and link an earlier guest booking. To link a guest booking, use its reference and the phone number used when booking."},
    {q:"How do saved or favourite shops work?",keys:["favourite","favorite","save shop","saved shop","heart","favourites"],a:"Tap the heart on a shop card to save it. If you are browsing as a guest, saved shops stay on that device. If you are signed in, your saved shops are linked to your account and can sync across devices."},
    {q:"How do shisanyama bookings work?",keys:["shisanyama","seats","table","people","guests","dine in","dine-in"],a:"A shisanyama may let you reserve seating and choose the number of guests. The available seating depends on the shop's table and seat capacity. Follow the options shown on that shop's page."},
    {q:"Can I order takeaway?",keys:["takeaway","take away","collection","collect","food order","menu items"],a:"Where a shisanyama offers takeaway, choose the takeaway option on its shop page, select the menu items and follow the checkout steps. Takeaway is for collection and does not reserve dine-in seating."},
    {q:"Will I get a booking reminder?",keys:["reminder","notification","alert","message","confirmation message","sms","whatsapp notification"],a:"BOOK.NOW is set up to send a message when the shop confirms your booking and a reminder 2 hours before the appointment. Push alerts depend on your device and app notification permissions. Check your booking receipt for the latest status."},
    {q:"Can I leave a review?",keys:["review","rating","stars","feedback","rate shop"],a:"After an eligible booking, the review option may appear in Manage booking. You can give a star rating and optionally write a comment. Your first name and last initial are shown with your review."},
    {q:"How do I contact the shop?",keys:["contact shop","call shop","shop whatsapp","message shop","business number","shop phone"],a:"Open the shop page to view its contact details. If your booking is already made, Manage booking may also show an option to message the shop on WhatsApp."},
    {q:"How do I contact BOOK.NOW support?",keys:["support","help","contact booknow","contact book now","complaint","problem","issue","human","person"],a:"You can email "+CONTACT.email+", call "+CONTACT.phone+", or WhatsApp BOOK.NOW support. For a shop's prices, service, opening hours or refund, contact that business directly."},
    {q:"Is BOOK.NOW responsible for the service I booked?",keys:["responsible","service quality","bad service","late","missed appointment","business owner"],a:"BOOK.NOW connects customers with independent businesses. The business provides the service and is responsible for its services, prices and handling refunds. Your booking is an arrangement between you and that business."}
  ];
  const QUICK = ["How do I make a booking?","How do I pay?","Cancel or change a booking","Where is my receipt?","I need support"];
  const normalize = value => String(value || "").toLowerCase().replace(/[^a-z0-9\\s]/g, " ").replace(/\\s+/g, " ").trim();
  function findAnswer(message) {
    const text = normalize(message);
    if (!text) return null;
    let best = null, score = 0;
    for (const item of FAQ) {
      let current = 0;
      for (const key of item.keys) {
        const term = normalize(key);
        if (term && text.includes(term)) current += term.includes(" ") ? 4 : 2;
      }
      const words = text.split(" ").filter(word => word.length > 3);
      for (const word of words) if (normalize(item.q).split(" ").includes(word)) current += 1;
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
      const match=findAnswer(question);
      addBubble(match ? match.a : "I’m not sure about that, and I don’t want to guess. Try asking about shops, bookings, payments, receipts, accounts or reviews. You can also contact BOOK.NOW support on WhatsApp.","bot");
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
