/* BOOK.NOW language support: English, isiZulu, Afrikaans, Sesotho.
   Add this script to a page and its visible text is translated. Anything without a translation stays in English.
   The translations are a first draft and should be reviewed by a native speaker.
   Each entry is  "English text": [isiZulu, Afrikaans, Sesotho]  */
(function () {
  "use strict";

  var LANGS = { en: "English", zu: "isiZulu", af: "Afrikaans", st: "Sesotho" };
  var IDX = { zu: 0, af: 1, st: 2 };

  var D = {
    // ---- general ----
    "All Spots": ["Zonke Izindawo", "Alle Plekke", "Libaka Tsohle"],
    "\u2190 All Spots": ["\u2190 Zonke Izindawo", "\u2190 Alle Plekke", "\u2190 Libaka Tsohle"],
    "Partner Portal": ["Iphothali Yabalingani", "Vennootportaal", "Portal ya Balekane"],
    "Privacy Policy": ["Inqubomgomo Yobumfihlo", "Privaatheidsbeleid", "Leano la Lekunutu"],
    "Terms of Use": ["Imigomo Yokusetshenziswa", "Gebruiksvoorwaardes", "Melao ea Tšebeliso"],
    "Terms": ["Imigomo", "Voorwaardes", "Melao"],
    "and": ["kanye ne", "en", "le"],
    "Manage my booking": ["Phatha ukubhuka kwami", "Bestuur my bespreking", "Laola buka ea ka"],
    "Close": ["Vala", "Maak toe", "Koala"],
    "Done": ["Kuphelile", "Klaar", "Ho phethiloe"],
    "Closed": ["Valiwe", "Toe", "E koetsoe"],
    "Open now": ["Vuliwe manje", "Nou oop", "E bulehile hona joale"],
    "Call": ["Shayela", "Bel", "Founela"],
    "Book": ["Bhuka", "Bespreek", "Bukha"],

    // ---- homepage ----
    "Verified Local Vendors": ["Abathengisi Basekhaya Abaqinisekisiwe", "Geverifieerde Plaaslike Verskaffers", "Barekisi ba Lehae ba Netefalitsweng"],
    "Explore Local Spots": ["Hlola Izindawo Zasekhaya", "Verken Plaaslike Plekke", "Hlahloba Libaka tsa Heno"],
    "Find and book barbershops, beauty salons, and braai spots near you.": ["Thola futhi ubhukhe amabhabhela, amasaloni, nama-shisanyama eduze nawe.", "Vind en bespreek barbiere, skoonheidsalonne en braaiplekke naby jou.", "Fumana 'me u bukhe barbara, li-salon tsa botle le libaka tsa shisanyama haufi le uena."],
    "Search by shop name, service, or category...": ["Sesha ngegama lesitolo, isevisi, noma isigaba...", "Soek volgens winkelnaam, diens of kategorie...", "Batla ka lebitso la lebenkele, ts'ebeletso kapa sehlopha..."],
    "Search shops": ["Sesha izitolo", "Soek winkels", "Batla mabenkele"],
    "Filter by category": ["Hlunga ngesigaba", "Filter volgens kategorie", "Sefa ka sehlopha"],
    "Barbershops": ["Amabhabhela", "Barbiere", "Barbara"],
    "Salons": ["Amasaloni", "Salonne", "Li-salon"],
    "Shisanyama": ["Ishisanyama", "Shisanyama", "Shisanyama"],
    "All areas": ["Zonke izindawo", "Alle areas", "Libaka tsohle"],
    "Filter by area": ["Hlunga ngendawo", "Filter volgens area", "Sefa ka sebaka"],
    "Sort shops": ["Hlela izitolo", "Sorteer winkels", "Hlophisa mabenkele"],
    "Newest first": ["Ezintsha kuqala", "Nuutste eerste", "Tse ncha pele"],
    "Top rated": ["Ezilinganiswe kakhulu", "Hoogs gegradeer", "Tse ratehang haholo"],
    "Name A to Z": ["Igama A kuya ku-Z", "Naam A tot Z", "Lebitso A ho ea ho Z"],
    "Loading available stores...": ["Ilanda izitolo ezitholakalayo...", "Laai beskikbare winkels...", "E kenya mabenkele a fumanehang..."],
    "View and book": ["Buka ubhuke", "Kyk en bespreek", "Sheba 'me u bukhe"],
    "No shops match your search. Try a different word or category.": ["Azikho izitolo ezifanele ukusesha kwakho. Zama elinye igama noma isigaba.", "Geen winkels pas by jou soektog nie. Probeer 'n ander woord of kategorie.", "Ha ho mabenkele a lumellanang le tsela ea hau ea ho batla. Leka lentsoe le leng kapa sehlopha."],
    "No shops are listed yet. Check back soon.": ["Azikho izitolo ezidwetshiwe okwamanje. Buya maduze.", "Daar is nog geen winkels gelys nie. Kom kyk gou weer.", "Ha ho mabenkele a ngoliselitsoeng ha ho sa le joale. Kopa u khutlele haufinyane."],
    "Own a barbershop, salon or shisanyama?": ["Unesitolo sokunquma izinwele, isaloni noma ishisanyama?", "Besit jy 'n barbier, salon of shisanyama?", "Na u na le lebenkele la barbara, salon kapa shisanyama?"],
    "Get bookings online and keep 100% of what customers pay.": ["Thola ukubhuka ku-inthanethi futhi ugcine u-100% walokho abathengi abakhokhayo.", "Kry besprekings aanlyn en hou 100% van wat kliënte betaal.", "Fumana libuka ka inthanete 'me u boloke 100% ea seo bareki ba se lefang."],
    "List your business": ["Bhalisa ibhizinisi lakho", "Lys jou besigheid", "Ngolisa khoebo ea hau"],

    // ---- shop page ----
    "Services & Menu": ["Izinsizakalo Nemenyu", "Dienste en Spyskaart", "Ditshebeletso le Menyu"],
    "Reviews": ["Ukubuyekezwa", "Resensies", "Maikutlo"],
    "Loading menu items...": ["Ilanda izinto zemenyu...", "Laai spyskaartitems...", "E kenya lintho tsa menyu..."],
    "Loading store info...": ["Ilanda ulwazi lwesitolo...", "Laai winkelinligting...", "E kenya tlhahisoleseling ea lebenkele..."],
    "Store Front \u2014 BOOK.NOW": ["Isitolo \u2014 BOOK.NOW", "Winkel \u2014 BOOK.NOW", "Lebenkele \u2014 BOOK.NOW"],
    "Get directions": ["Thola izikhombisi", "Kry rigting", "Fumana tataiso"],
    "Share this shop": ["Yabelana ngalesi sitolo", "Deel hierdie winkel", "Arolelana lebenkele lena"],
    "Report this shop": ["Bika lesi sitolo", "Rapporteer hierdie winkel", "Tlaleha lebenkele lena"],
    "Book your appointment": ["Bhuka isikhathi sakho", "Bespreek jou afspraak", "Bukha nako ea hau"],
    "Your Full Name": ["Igama Lakho Eliphelele", "Jou Volle Naam", "Lebitso la Hau le Felletseng"],
    "Phone Number (WhatsApp)": ["Inombolo Yocingo (WhatsApp)", "Foonnommer (WhatsApp)", "Nomoro ea Mohala (WhatsApp)"],
    "Number of People": ["Inani Labantu", "Aantal Mense", "Palo ea Batho"],
    "Appointment Date": ["Usuku Lokubhuka", "Afspraakdatum", "Letsatsi la Kopano"],
    "Appointment Time": ["Isikhathi Sokubhuka", "Afspraaktyd", "Nako ea Kopano"],
    "Choose a date first": ["Khetha usuku kuqala", "Kies eers 'n datum", "Khetha letsatsi pele"],
    "Choose a time": ["Khetha isikhathi", "Kies 'n tyd", "Khetha nako"],
    "No times available": ["Azikho izikhathi ezitholakalayo", "Geen tye beskikbaar nie", "Ha ho linako tse fumanehang"],
    "Payment Method": ["Indlela Yokukhokha", "Betaalmetode", "Mokhoa oa ho Lefa"],
    "Instant EFT (Direct)": ["I-EFT Ngokushesha (Ngqo)", "Kitsmatige EFT (Direk)", "EFT hang-hang (Ka Kotloloho)"],
    "Pay Cash": ["Khokha Ngemali", "Betaal Kontant", "Lefa ka Chelete"],
    "Pay by EFT": ["Khokha nge-EFT", "Betaal per EFT", "Lefa ka EFT"],
    "After you confirm, you'll get a unique payment reference and this shop's bank details.": ["Ngemva kokuqinisekisa, uzothola inkomba yokukhokha eyingqayizivele nemininingwane yebhange yalesi sitolo.", "Nadat jy bevestig het, kry jy 'n unieke betaalverwysing en hierdie winkel se bankbesonderhede.", "Kamora ho netefatsa, u tla fumana tlhaloso ea tefo e ikhethileng le lintlha tsa banka tsa lebenkele lena."],
    "Confirm Appointment": ["Qinisekisa Isikhathi", "Bevestig Afspraak", "Netefatsa Kopano"],
    "Close booking form": ["Vala ifomu", "Maak vorm toe", "Koala foromo"],
    "Close photo": ["Vala isithombe", "Maak foto toe", "Koala senepe"],
    "Photo viewer": ["Isibukeli sezithombe", "Fotovertoner", "Sebali sa lifoto"],
    "Full view": ["Ukubuka okugcwele", "Volskermvertoning", "Pono e felletseng"],
    "By confirming, you agree to our": ["Ngokuqinisekisa, uyavumelana ne", "Deur te bevestig, stem jy in tot ons", "Ka ho netefatsa, u dumela ho"],
    ". Your name and phone number are shared with the shop.": [". Igama lakho nenombolo yocingo kwabelwana nesitolo.", ". Jou naam en foonnommer word met die winkel gedeel.", ". Lebitso la hau le nomoro ea mohala li arolelanoa le lebenkele."],
    "Enter your full name.": ["Faka igama lakho eliphelele.", "Voer jou volle naam in.", "Kenya lebitso la hau le felletseng."],
    "Enter a valid phone number.": ["Faka inombolo yocingo evumelekile.", "Voer 'n geldige foonnommer in.", "Kenya nomoro ea mohala e nepahetseng."],
    "Choose your appointment date.": ["Khetha usuku lokubhuka kwakho.", "Kies jou afspraakdatum.", "Khetha letsatsi la kopano ea hau."],
    "Choose your appointment time.": ["Khetha isikhathi sokubhuka kwakho.", "Kies jou afspraaktyd.", "Khetha nako ea kopano ea hau."],
    "Submitting booking...": ["Iyathumela ukubhuka...", "Dien bespreking in...", "E romela buka..."],
    "We couldn't save your booking. Check your connection and try again.": ["Asikwazanga ukulondoloza ukubhuka kwakho. Hlola uxhumano lwakho uphinde uzame.", "Ons kon nie jou bespreking stoor nie. Kyk jou verbinding en probeer weer.", "Re ne re sa khone ho boloka buka ea hau. Hlahloba khokahano 'me u leke hape."],
    "That time just filled up. Please choose another time.": ["Lesi sikhathi sivele sagcwala. Sicela ukhethe esinye.", "Daardie tyd het pas vol geraak. Kies asseblief 'n ander tyd.", "Nako eo e tletse hona joale. Ka kopo khetha e 'ngoe."],
    "The shop is closed on this date. Try another day.": ["Isitolo sivaliwe kulolu suku. Zama olunye usuku.", "Die winkel is op hierdie datum gesluit. Probeer 'n ander dag.", "Lebenkele le koetsoe ka letsatsi lena. Leka le leng."],
    "What is the problem?": ["Kuyini inkinga?", "Wat is die probleem?", "Bothata ke bofe?"],
    "Choose a reason": ["Khetha isizathu", "Kies 'n rede", "Khetha lebaka"],
    "Wrong information (prices, hours, address)": ["Ulwazi olungalungile (amanani, amahora, ikheli)", "Verkeerde inligting (pryse, ure, adres)", "Tlhahisoleseling e fosahetseng (litheko, nako, aterese)"],
    "I felt unsafe or was treated badly": ["Ngizizwe ngingavikelekile noma ngiphathwe kabi", "Ek het onveilig gevoel of is sleg behandel", "Ke ne ke sa ikutloe ke bolokehile kapa ke ile ka tšoaroa hampe"],
    "This looks like a scam": ["Lokhu kubukeka njengenkohliso", "Dit lyk soos 'n swendelary", "Sena se shebahala joaloka thetso"],
    "Something else": ["Okunye", "Iets anders", "Ntho e 'ngoe"],
    "Tell us more (optional)": ["Sitshele kabanzi (ngokuzithandela)", "Vertel ons meer (opsioneel)", "Re bolelle haholoanyane (ha u rata)"],
    "What happened?": ["Kwenzekeni?", "Wat het gebeur?", "Ho etsahetse'ng?"],
    "Your phone or email, if we may contact you (optional)": ["Ifoni noma i-imeyili yakho, uma sivunyelwe ukukuthinta (ngokuzithandela)", "Jou foon of e-pos, as ons jou mag kontak (opsioneel)", "Mohala kapa lengolo-tsa-motlakase la hau, haeba re ka u founela (ha u rata)"],
    "Send report": ["Thumela umbiko", "Stuur verslag", "Romela tlaleho"],
    "Thank you. We will look into it.": ["Siyabonga. Sizokubheka.", "Dankie. Ons sal dit ondersoek.", "Kea leboha. Re tla e hlahloba."],

    // ---- receipt ----
    "Service:": ["Isevisi:", "Diens:", "Ts'ebeletso:"],
    "Appointment:": ["Isikhathi:", "Afspraak:", "Nako ea kopano:"],
    "Guests:": ["Izivakashi:", "Gaste:", "Baeti:"],
    "Name:": ["Igama:", "Naam:", "Lebitso:"],
    "Phone:": ["Ifoni:", "Foon:", "Mohala:"],
    "Bank:": ["Ibhange:", "Bank:", "Banka:"],
    "Account name:": ["Igama le-akhawunti:", "Rekeningnaam:", "Lebitso la akhaonto:"],
    "Account number:": ["Inombolo ye-akhawunti:", "Rekeningnommer:", "Nomoro ea akhaonto:"],
    "Branch code:": ["Ikhodi yegatsha:", "Takkode:", "Khoutu ea lekala:"],
    "Use this payment reference": ["Sebenzisa le nkomba yokukhokha", "Gebruik hierdie betaalverwysing", "Sebelisa tlhaloso ena ea tefo"],
    "Send booking to the shop on WhatsApp": ["Thumela ukubhuka esitolo ku-WhatsApp", "Stuur bespreking na die winkel op WhatsApp", "Romela buka lebenkeleng ho WhatsApp"],
    "Get alerts for this booking": ["Thola izexwayiso zalokhu kubhuka", "Kry waarskuwings vir hierdie bespreking", "Fumana litlhokomeliso tsa buka ena"],
    "Alerts are on": ["Izexwayiso ziyasebenza", "Waarskuwings is aan", "Litlhokomeliso lia sebetsa"],
    "A message when the shop confirms, and a reminder 2 hours before.": ["Umyalezo uma isitolo siqinisekisa, nesikhumbuzo ngamahora angu-2 ngaphambili.", "'n Boodskap wanneer die winkel bevestig, en 'n herinnering 2 uur vooraf.", "Molaetsa ha lebenkele le netefatsa, le sehopotso lihora tse 2 pele."],
    "Need to change or cancel? Manage your booking": ["Udinga ukushintsha noma ukukhansela? Phatha ukubhuka kwakho", "Moet jy verander of kanselleer? Bestuur jou bespreking", "U hloka ho fetola kapa ho hlakola? Laola buka ea hau"],

    // ---- manage booking ----
    "Manage your booking": ["Phatha ukubhuka kwakho", "Bestuur jou bespreking", "Laola buka ea hau"],
    "Manage your booking | BOOK.NOW": ["Phatha ukubhuka kwakho | BOOK.NOW", "Bestuur jou bespreking | BOOK.NOW", "Laola buka ea hau | BOOK.NOW"],
    "Enter the payment reference from your booking receipt and the phone number you booked with. You can then change the date or time, or cancel.": ["Faka inkomba yokukhokha ephuma kurisidi yakho yokubhuka nenombolo yocingo obhukhe ngayo. Ungashintsha usuku noma isikhathi, noma ukhansele.", "Voer die betaalverwysing van jou bespreking-kwitansie in en die foonnommer waarmee jy bespreek het. Jy kan dan die datum of tyd verander, of kanselleer.", "Kenya tlhaloso ea tefo e tsoang rasiting ea hau ea buka le nomoro ea mohala eo u bukileng ka eona. Joale u ka fetola letsatsi kapa nako, kapa ua hlakola."],
    "Payment reference": ["Inkomba yokukhokha", "Betaalverwysing", "Tlhaloso ea tefo"],
    "Phone number": ["Inombolo yocingo", "Foonnommer", "Nomoro ea mohala"],
    "Find my booking": ["Thola ukubhuka kwami", "Vind my bespreking", "Fumana buka ea ka"],
    "Service": ["Isevisi", "Diens", "Ts'ebeletso"],
    "Appointment": ["Isikhathi", "Afspraak", "Nako ea kopano"],
    "Guests": ["Izivakashi", "Gaste", "Baeti"],
    "Price": ["Intengo", "Prys", "Theko"],
    "Payment": ["Inkokhelo", "Betaling", "Tefo"],
    "Reference": ["Inkomba", "Verwysing", "Tlhaloso"],
    "Waiting for the shop to confirm": ["Kulindelwe isitolo siqinisekise", "Wag vir die winkel om te bevestig", "E emetse hore lebenkele le netefatse"],
    "Confirmed by the shop": ["Kuqinisekiswe yisitolo", "Deur die winkel bevestig", "E netefalitsoe ke lebenkele"],
    "Completed": ["Kuqediwe", "Voltooi", "E phethiloe"],
    "Cancelled": ["Kukhanselwe", "Gekanselleer", "E hlakotsoe"],
    "Change date or time": ["Shintsha usuku noma isikhathi", "Verander datum of tyd", "Fetola letsatsi kapa nako"],
    "Cancel booking": ["Khansela ukubhuka", "Kanselleer bespreking", "Hlakola buka"],
    "You can change or cancel until 2 hours before your appointment.": ["Ungashintsha noma ukhansele kuze kube amahora angu-2 ngaphambi kwesikhathi sakho.", "Jy kan tot 2 uur voor jou afspraak verander of kanselleer.", "U ka fetola kapa ua hlakola ho fihlela lihora tse 2 pele ho nako ea hau."],
    "New date": ["Usuku olusha", "Nuwe datum", "Letsatsi le lecha"],
    "New time": ["Isikhathi esisha", "Nuwe tyd", "Nako e ncha"],
    "Confirm new time": ["Qinisekisa isikhathi esisha", "Bevestig nuwe tyd", "Netefatsa nako e ncha"],
    "Message the shop on WhatsApp": ["Thumela umyalezo esitolo ku-WhatsApp", "Stuur die winkel 'n boodskap op WhatsApp", "Romella lebenkele molaetsa ho WhatsApp"],
    "Show bank details to pay by EFT": ["Bonisa imininingwane yebhange ukukhokha nge-EFT", "Wys bankbesonderhede om per EFT te betaal", "Bonisa lintlha tsa banka ho lefa ka EFT"],
    "Account name": ["Igama le-akhawunti", "Rekeningnaam", "Lebitso la akhaonto"],
    "Account number": ["Inombolo ye-akhawunti", "Rekeningnommer", "Nomoro ea akhaonto"],
    "Branch code": ["Ikhodi yegatsha", "Takkode", "Khoutu ea lekala"],
    "Bank": ["Ibhange", "Bank", "Banka"],
    "Use this reference": ["Sebenzisa le nkomba", "Gebruik hierdie verwysing", "Sebelisa tlhaloso ena"],
    "How was your visit?": ["Bekunjani ukuvakasha kwakho?", "Hoe was jou besoek?", "Ho ile ha e-ba joang ketelo ea hau?"],
    "Your review (optional)": ["Ukubuyekeza kwakho (ngokuzithandela)", "Jou resensie (opsioneel)", "Maikutlo a hau (ha u rata)"],
    "Tell others what you liked": ["Tshela abanye ukuthi bekuthandekile", "Vertel ander wat jy gehou het", "Bolella ba bang seo u se ratileng"],
    "Submit review": ["Thumela ukubuyekeza", "Dien resensie in", "Romela maikutlo"],
    "Your first name and last initial are shown with your review.": ["Igama lakho lokuqala nohlamvu lokugcina kuboniswa nokubuyekeza kwakho.", "Jou eerste naam en laaste voorletter word saam met jou resensie gewys.", "Lebitso la hau la pele le tlhaku ea ho qetela li bontšoa le maikutlo a hau."],
    "Rating out of 5": ["Izinga kokungu-5", "Gradering uit 5", "Boemo ho ea ho 5"],
    "e.g. BN-ABC123": ["isb. BN-ABC123", "bv. BN-ABC123", "mohlala BN-ABC123"],
    "e.g. 082 123 4567": ["isb. 082 123 4567", "bv. 082 123 4567", "mohlala 082 123 4567"],
    "Your booking is cancelled.": ["Ukubhuka kwakho kukhanselwe.", "Jou bespreking is gekanselleer.", "Buka ea hau e hlakotsoe."],
    "Thank you for your review!": ["Siyabonga ngokubuyekeza kwakho!", "Dankie vir jou resensie!", "Kea leboha ka maikutlo a hau!"],
    "Your booking has been moved. The shop will confirm your new time.": ["Ukubhuka kwakho kuhanjisiwe. Isitolo sizoqinisekisa isikhathi sakho esisha.", "Jou bespreking is verskuif. Die winkel sal jou nuwe tyd bevestig.", "Buka ea hau e fetotsoe. Lebenkele le tla netefatsa nako ea hau e ncha."],
    "We couldn't find a booking with that reference and phone number. Check them and try again.": ["Asitholanga ukubhuka nalokho kubhuka nenombolo yocingo. Zihlole uphinde uzame.", "Ons kon nie 'n bespreking met daardie verwysing en foonnommer vind nie. Kontroleer hulle en probeer weer.", "Re ne re sa fumane buka e nang le tlhaloso eo le nomoro eo ea mohala. Li hlahlobe 'me u leke hape."],
    "Cancel this booking? This can't be undone.": ["Khansela lokhu kubhuka? Lokhu akunakuhlehliswa.", "Kanselleer hierdie bespreking? Dit kan nie ongedaan gemaak word nie.", "Hlakola buka ena? Sena se ke ke sa busetsoa morao."]
  };

  // Sentences that contain numbers or names are matched with patterns. $1 $2 are filled in.
  var PAT = [
    [/^(\d+) services$/, ["izinsizakalo ezingu-$1", "$1 dienste", "ditshebeletso tse $1"]],
    [/^1 service$/, ["isevisi e-1", "1 diens", "ts'ebeletso e 1"]],
    [/^Takes (.+)$/, ["Kuthatha $1", "Neem $1", "E nka $1"]],
    [/^(.+) \((\d+) left\)$/, ["$1 (kusele $2)", "$1 ($2 oor)", "$1 (ho setse $2)"]],
    [/^(.+) \(only (\d+) left\)$/, ["$1 (kusele $2 kuphela)", "$1 (slegs $2 oor)", "$1 (ho setse tse $2 feela)"]],
    [/^(.+) \(full\)$/, ["$1 (igcwele)", "$1 (vol)", "$1 (e tletse)"]],
    [/^(.+) \(booked\)$/, ["$1 (ibhukiwe)", "$1 (bespreek)", "$1 (e bukiloe)"]],
    [/^(.+) \(your current time\)$/, ["$1 (isikhathi sakho samanje)", "$1 (jou huidige tyd)", "$1 (nako ea hau ea hajoale)"]],
    [/^APPOINTMENT: (.+)$/, ["ISIKHATHI ESIBEKIWE: $1", "AFSPRAAK: $1", "NAKO EA KOPANO: $1"]],
    [/^Bank details for (.+)$/, ["Imininingwane yebhange ye-$1", "Bankbesonderhede vir $1", "Lintlha tsa banka tsa $1"]],
    [/^Unpaid\. Ref: (.+)$/, ["Akukakhokhwa. Inkomba: $1", "Onbetaal. Verw: $1", "Ha e so lefshoe. Tlhaloso: $1"]],
    [/^Enter how many people are coming \(up to (\d+)\)\.$/, ["Faka ukuthi bangaki abantu abeza (kufika ku-$1).", "Voer in hoeveel mense kom (tot $1).", "Kenya hore na ke batho ba bakae ba tlang (ho fihla ho $1)."]],
    [/^This shop seats up to (\d+) people at one time\.$/, ["Lesi sitolo singahlalisa abantu abangafika ku-$1 ngesikhathi esisodwa.", "Hierdie winkel kan tot $1 mense op 'n slag huisves.", "Lebenkele lena le ka lula batho ba fihlang ho $1 ka nako e le 'ngoe."]],
    [/^(\d+) reviews?\)$/, ["$1)", "$1)", "$1)"]]
  ];

  var lang = "en";
  try { lang = localStorage.getItem("bn_lang") || "en"; } catch (e) {}
  if (!LANGS[lang]) lang = "en";
  document.documentElement.lang = lang;
  window.BN_LANG = lang;

  function fill(tpl, m) { return tpl.replace(/\$(\d)/g, function (_, i) { return m[i] || ""; }); }

  function tr(text) {
    if (lang === "en" || typeof text !== "string") return text;
    var i = IDX[lang];
    var hit = D[text];
    if (hit && hit[i]) return hit[i];
    for (var p = 0; p < PAT.length; p++) {
      var m = text.match(PAT[p][0]);
      if (m) return fill(PAT[p][1][i], m);
    }
    return text;
  }
  window.T = tr;

  var SKIP = { SCRIPT: 1, STYLE: 1, TEXTAREA: 1, NOSCRIPT: 1 };
  function translateTextNode(node) {
    var raw = node.nodeValue;
    var trimmed = raw && raw.trim();
    if (!trimmed) return;
    var out = tr(trimmed);
    if (out !== trimmed) node.nodeValue = raw.replace(trimmed, out);
  }
  function translateAttrs(el) {
    ["placeholder", "aria-label", "title"].forEach(function (a) {
      var v = el.getAttribute && el.getAttribute(a);
      if (v) { var out = tr(v.trim()); if (out !== v.trim()) el.setAttribute(a, out); }
    });
  }
  function translateTree(root) {
    if (!root) return;
    if (root.nodeType === 3) { if (!root.parentNode || !SKIP[root.parentNode.nodeName]) translateTextNode(root); return; }
    if (root.nodeType !== 1 || SKIP[root.nodeName] || (root.closest && root.closest("[data-no-i18n]"))) return;
    translateAttrs(root);
    var w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null);
    var n;
    while ((n = w.nextNode())) {
      if (n.nodeType === 3) { if (!SKIP[n.parentNode.nodeName] && !(n.parentNode.closest && n.parentNode.closest("[data-no-i18n]"))) translateTextNode(n); }
      else translateAttrs(n);
    }
  }

  function addPicker() {
    var sel = document.createElement("select");
    sel.id = "lang-select";
    sel.setAttribute("aria-label", "Language");
    sel.setAttribute("data-no-i18n", "");
    sel.style.cssText = "padding:5px 8px;border-radius:8px;border:1px solid #e2e8f0;font-size:12px;font-weight:700;background:#fff;color:#0f172a;max-width:104px;margin-left:8px;";
    Object.keys(LANGS).forEach(function (code) {
      var o = document.createElement("option");
      o.value = code; o.textContent = LANGS[code];
      if (code === lang) o.selected = true;
      sel.appendChild(o);
    });
    sel.addEventListener("change", function () {
      try { localStorage.setItem("bn_lang", sel.value); } catch (e) {}
      location.reload();
    });
    var nav = document.querySelector(".top-nav");
    if (nav) nav.appendChild(sel);
    else { sel.style.cssText += "position:fixed;top:10px;right:10px;z-index:50;"; document.body.appendChild(sel); }
  }

  function start() {
    addPicker();
    if (lang === "en") return;
    translateTree(document.body);
    document.title = tr(document.title);
    new MutationObserver(function (records) {
      records.forEach(function (r) {
        if (r.type === "characterData") translateTree(r.target);
        else if (r.type === "attributes") translateAttrs(r.target);
        else r.addedNodes.forEach(translateTree);
      });
    }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ["placeholder", "aria-label", "title"] });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
