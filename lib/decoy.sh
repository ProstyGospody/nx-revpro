#!/usr/bin/env bash
# decoy.sh — генератор сайта-прикрытия.
#
# Нужен обычный скучный сайт небольшой конторы: он отдаётся всем, кто пришёл
# на decoy-домен без валидного VLESS-рукопожатия, и должен выглядеть как то,
# ради чего домен вообще существует. Ниша, название, палитра и цифры выбираются
# случайно при первой установке и запоминаются в state.
# shellcheck shell=bash

DECOY_FIRST=(Northwind Aster Cobalt Larkfield Halden Brightwater Kestrel Orchard
             Pinemark Redwing Sable Thornhill Vantage Wexford Ironvale Silverbrook
             Cedarhall Foxglove Marlowe Quarrystone Ashcombe Fenwick Hollowbrook)

DECOY_FONTS=(
  '"Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif'
  'Inter, "Segoe UI", system-ui, -apple-system, sans-serif'
  'Georgia, "Times New Roman", serif'
  '"IBM Plex Sans", "Segoe UI", system-ui, sans-serif'
)

# accent|accent_dark|bg|surface|border|text|muted
DECOY_PALETTES=(
  '#1f6feb|#12457f|#ffffff|#f6f8fa|#d8dee4|#1b2028|#5a6472'
  '#0f766e|#0a544e|#fbfdfc|#eef6f4|#cfe3df|#12211f|#4d6360'
  '#b45309|#8a3f07|#fffdf9|#fdf4e7|#ecdcc2|#2a2118|#6b5a45'
  '#4c51bf|#363b96|#ffffff|#f2f3fb|#d9dbf0|#1c1e2b|#5c6079'
  '#0b4f6c|#08394e|#ffffff|#eef4f7|#ccdde5|#132028|#4f6570'
  '#7c2d54|#5b1f3d|#fffbfd|#faeff4|#e8d0dd|#26161e|#6d5560'
)

# decoy_pick_niche — выставляет DK_* по случайной нише.
decoy_pick_niche() {
    local -a second
    case $(( RANDOM % 10 )) in
      0) DK_KIND="logistics"; second=(Logistics Freight "Supply Co." Transport)
         DK_TAG="Regional freight, handled properly"
         DK_LEAD="Palletised road freight and warehousing across the region since @@YEAR@@. Fixed slots, one dispatcher, no surprises on the invoice."
         DK_S1="Road freight::Scheduled overnight runs between our depots, with tail-lift and side-loader options."
         DK_S2="Warehousing::Racked, sprinklered storage billed by pallet-week. Pick and pack on request."
         DK_S3="Customs paperwork::Export documents, T1 transit and EORI checks prepared before the truck moves."
         DK_ST1="depots"; DK_ST2="pallets moved / week"; DK_ST3="on-time delivery" ;;
      1) DK_KIND="dental"; second=("Dental Care" "Dental Practice" Dental Orthodontics)
         DK_TAG="Careful dentistry, unhurried appointments"
         DK_LEAD="A family practice with two surgeries and a hygienist, open since @@YEAR@@. We book longer slots so nobody is rushed."
         DK_S1="General dentistry::Check-ups, fillings and extractions with digital radiography and same-day reporting."
         DK_S2="Hygiene::Scale and polish, periodontal charting and a plan you can actually keep up with."
         DK_S3="Cosmetic work::Whitening, veneers and composite bonding, quoted in writing before we start."
         DK_ST1="surgeries"; DK_ST2="registered patients"; DK_ST3="would recommend us" ;;
      2) DK_KIND="accounting"; second=(Accounting "and Partners" Bookkeeping Advisory)
         DK_TAG="Books that balance, filings that land on time"
         DK_LEAD="Bookkeeping and statutory accounts for owner-managed businesses. Independent since @@YEAR@@, and still answering the phone ourselves."
         DK_S1="Bookkeeping::Monthly reconciliation, VAT returns and a management pack you can read in five minutes."
         DK_S2="Year-end accounts::Statutory accounts and corporation tax, filed early rather than on the deadline."
         DK_S3="Payroll::RTI submissions, pensions and payslips for teams from two people upwards."
         DK_ST1="years independent"; DK_ST2="client businesses"; DK_ST3="filed before deadline" ;;
      3) DK_KIND="landscaping"; second=(Landscapes Groundworks "Garden Co." Grounds)
         DK_TAG="Gardens and grounds, maintained year round"
         DK_LEAD="Design, build and maintenance for private gardens and commercial grounds. Working the same patch of the county since @@YEAR@@."
         DK_S1="Garden design::Measured survey, planting plan and a build schedule priced line by line."
         DK_S2="Hard landscaping::Patios, retaining walls, drainage and fencing, built to last a decade of winters."
         DK_S3="Maintenance::Fortnightly visits, seasonal cutbacks and a written plan for the year ahead."
         DK_ST1="crews"; DK_ST2="sites maintained"; DK_ST3="contracts renewed" ;;
      4) DK_KIND="hvac"; second=("Heating and Cooling" "Climate Services" Mechanical "HVAC Services")
         DK_TAG="Heating and ventilation that keeps running"
         DK_LEAD="Installation and service of commercial heating, cooling and ventilation. Family-run since @@YEAR@@, with our own engineers on call."
         DK_S1="Installation::Heat pumps, split systems and AHUs, sized from a proper load calculation rather than a guess."
         DK_S2="Planned maintenance::Quarterly service visits with F-Gas logging and a report you can hand to your insurer."
         DK_S3="Breakdown cover::Four-hour response inside the county, parts van stocked for the kit we install."
         DK_ST1="engineers"; DK_ST2="sites under contract"; DK_ST3="first-visit fixes" ;;
      5) DK_KIND="translation"; second=("Language Services" Translation Linguistics Localisation)
         DK_TAG="Translation that reads like it was written here"
         DK_LEAD="Technical and legal translation into eleven languages, with a named reviser on every file. Trading since @@YEAR@@."
         DK_S1="Technical translation::Manuals, datasheets and specifications, handled by translators who know the field."
         DK_S2="Certified documents::Sworn translations for courts, registries and immigration, with hard copies posted."
         DK_S3="Localisation::Software strings and product copy, delivered in your format with the placeholders intact."
         DK_ST1="working languages"; DK_ST2="words per month"; DK_ST3="delivered on schedule" ;;
      6) DK_KIND="hotel"; second=(House "Guest House" Inn Lodgings)
         DK_TAG="Eleven rooms, a decent breakfast, no piped music"
         DK_LEAD="A small guest house in a converted mill, run by the same family since @@YEAR@@. Book direct and we will hold the room you asked for."
         DK_S1="Rooms::Eleven rooms across two floors, all with proper beds, blackout blinds and a kettle that works."
         DK_S2="Breakfast::Cooked to order between seven and ten, with bread from the bakery two streets over."
         DK_S3="Meetings::A quiet ground-floor room for up to fourteen people, with coffee and no hourly minimum."
         DK_ST1="rooms"; DK_ST2="years under one family"; DK_ST3="guests who return" ;;
      7) DK_KIND="itconsult"; second=("IT Services" Systems Technology Computing)
         DK_TAG="Boring, reliable IT for small offices"
         DK_LEAD="Managed IT for firms of five to eighty people. Fixed monthly fee, on-site when it matters. Independent since @@YEAR@@."
         DK_S1="Managed support::Helpdesk with a named engineer, patching, backups and a monthly report nobody has to chase."
         DK_S2="Networks::Structured cabling, switching and wireless designed for the building you actually have."
         DK_S3="Migrations::Server and mailbox moves done over a weekend, with a written rollback plan."
         DK_ST1="engineers"; DK_ST2="workstations managed"; DK_ST3="tickets closed same day" ;;
      8) DK_KIND="roastery"; second=("Coffee Roasters" "Coffee Co." Roastery "Coffee Works")
         DK_TAG="Small-batch roasting, roasted to order"
         DK_LEAD="We roast on a 12kg drum three mornings a week and ship the same afternoon. Roasting since @@YEAR@@."
         DK_S1="Wholesale::Weekly standing orders for cafes and offices, with grind set to your machine and loan grinders."
         DK_S2="Subscriptions::Choose a weight and a cadence; we roast the day before it leaves the building."
         DK_S3="Training::Half-day dial-in sessions on your own equipment, in your own shop, not a demo bar."
         DK_ST1="kg roasted / week"; DK_ST2="wholesale accounts"; DK_ST3="orders shipped same day" ;;
      *) DK_KIND="surveying"; second=(Surveying "Land Surveys" "Survey Partners" Geomatics)
         DK_TAG="Measured surveys you can build from"
         DK_LEAD="Topographic, measured building and setting-out surveys for architects and contractors. Established @@YEAR@@."
         DK_S1="Topographic surveys::Site levels, drainage and services, delivered as clean layered DWG and PDF."
         DK_S2="Measured buildings::Floor plans, sections and elevations from laser scan data, with a point cloud on request."
         DK_S3="Setting out::Grid and level control on site, checked and signed off the same visit."
         DK_ST1="survey teams"; DK_ST2="sites per year"; DK_ST3="drawings issued on time" ;;
    esac
    DK_SECOND=$(rand_pick second)
}

_decoy_css() {
    mkdir -p "$NX_DECOY_ROOT/assets"
    tpl_render "$NX_DECOY_ROOT/assets/site.css" \
        ACCENT "$DK_ACCENT" ACCENT_DARK "$DK_ACCENT_DARK" BG "$DK_BG" \
        SURFACE "$DK_SURFACE" BORDER "$DK_BORDER" TEXT "$DK_TEXT" \
        MUTED "$DK_MUTED" FONT "$DK_FONT" RADIUS "$DK_RADIUS" <<'TPL'
:root {
  --accent: @@ACCENT@@;
  --accent-dark: @@ACCENT_DARK@@;
  --bg: @@BG@@;
  --surface: @@SURFACE@@;
  --border: @@BORDER@@;
  --text: @@TEXT@@;
  --muted: @@MUTED@@;
  --radius: @@RADIUS@@;
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  font-family: @@FONT@@;
  font-size: 17px;
  line-height: 1.65;
  color: var(--text);
  background: var(--bg);
}
.wrap { width: 100%; max-width: 1080px; margin: 0 auto; padding: 0 22px; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
h1, h2, h3 { line-height: 1.25; margin: 0 0 .5em; font-weight: 650; letter-spacing: -.01em; }
h1 { font-size: clamp(2rem, 5vw, 3rem); }
h2 { font-size: clamp(1.4rem, 3vw, 1.9rem); }
h3 { font-size: 1.12rem; }
p { margin: 0 0 1em; }

header {
  border-bottom: 1px solid var(--border);
  background: var(--bg);
  position: sticky; top: 0; z-index: 10;
}
.bar { display: flex; align-items: center; gap: 20px; min-height: 72px; }
.brand { display: flex; align-items: center; gap: 11px; font-weight: 700; color: var(--text); font-size: 1.06rem; }
.brand:hover { text-decoration: none; }
.mark { width: 34px; height: 34px; flex: 0 0 34px; border-radius: 9px; background: var(--accent);
        color: #fff; display: grid; place-items: center; font-weight: 700; font-size: 1rem; }
nav { margin-left: auto; display: flex; gap: 22px; flex-wrap: wrap; }
nav a { color: var(--muted); font-size: .95rem; }
nav a:hover { color: var(--text); text-decoration: none; }

.hero { padding: 78px 0 62px; }
.hero p.lead { font-size: 1.15rem; color: var(--muted); max-width: 62ch; }
.actions { display: flex; gap: 12px; flex-wrap: wrap; margin-top: 26px; }
.btn { display: inline-block; padding: 12px 22px; border-radius: var(--radius);
       background: var(--accent); color: #fff; font-weight: 600; font-size: .97rem; border: 1px solid var(--accent); }
.btn:hover { background: var(--accent-dark); border-color: var(--accent-dark); text-decoration: none; }
.btn.ghost { background: transparent; color: var(--text); border-color: var(--border); }
.btn.ghost:hover { background: var(--surface); }

section { padding: 56px 0; border-top: 1px solid var(--border); }
.grid { display: grid; gap: 20px; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 24px; }
.card h3 { margin-bottom: .35em; }
.card p { margin: 0; color: var(--muted); font-size: .97rem; }

.stats { display: grid; gap: 20px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }
.stat .n { font-size: 2.1rem; font-weight: 700; color: var(--accent); line-height: 1.1; }
.stat .l { color: var(--muted); font-size: .93rem; }

.split { display: grid; gap: 34px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); align-items: start; }
dl.contact { margin: 0; }
dl.contact dt { font-size: .82rem; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin-top: 16px; }
dl.contact dd { margin: 2px 0 0; }

footer { border-top: 1px solid var(--border); padding: 30px 0 46px; color: var(--muted); font-size: .9rem; }
footer .row { display: flex; gap: 18px; flex-wrap: wrap; align-items: center; }
footer nav { margin-left: auto; gap: 18px; }

.prose { max-width: 68ch; }
.prose h2 { margin-top: 1.6em; }
.prose ul { padding-left: 1.2em; color: var(--muted); }
TPL
}

_decoy_card() {
    local s=$1 title desc
    title=${s%%::*}; desc=${s#*::}
    printf '        <div class="card"><h3>%s</h3><p>%s</p></div>\n' "$title" "$desc"
}

# _decoy_page <файл> <заголовок вкладки> <html тела>
_decoy_page() {
    local out=$1 title=$2 body=$3
    tpl_render "$out" \
        TITLE "$title" BRAND "$DK_BRAND" INITIAL "$DK_INITIAL" \
        TAG "$DK_TAG" YEAR_NOW "$(date +%Y)" BODY "$body" <<'TPL'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@@TITLE@@</title>
<meta name="description" content="@@BRAND@@ — @@TAG@@.">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/site.css">
</head>
<body>
<header>
  <div class="wrap bar">
    <a class="brand" href="/"><span class="mark">@@INITIAL@@</span>@@BRAND@@</a>
    <nav>
      <a href="/#services">Services</a>
      <a href="/#about">About</a>
      <a href="/#contact">Contact</a>
    </nav>
  </div>
</header>

@@BODY@@

<footer>
  <div class="wrap row">
    <span>&copy; @@YEAR_NOW@@ @@BRAND@@. All rights reserved.</span>
    <nav>
      <a href="/privacy">Privacy</a>
      <a href="/terms">Terms</a>
    </nav>
  </div>
</footer>
</body>
</html>
TPL
}

_decoy_index() {
    local lead=${DK_LEAD//@@YEAR@@/$DK_YEAR}
    local cards
    cards=$( { _decoy_card "$DK_S1"; _decoy_card "$DK_S2"; _decoy_card "$DK_S3"; } )
    local body
    body=$(cat <<HTML
<main>
  <div class="wrap hero">
    <h1>${DK_TAG}</h1>
    <p class="lead">${lead}</p>
    <div class="actions">
      <a class="btn" href="#contact">Get in touch</a>
      <a class="btn ghost" href="#services">What we do</a>
    </div>
  </div>

  <section id="services">
    <div class="wrap">
      <h2>What we do</h2>
      <div class="grid">
${cards}
      </div>
    </div>
  </section>

  <section id="about">
    <div class="wrap split">
      <div>
        <h2>About us</h2>
        <p>${lead}</p>
        <p>We are a small team and we prefer it that way. You get the same
           people on the phone each time, and a written quote before any work
           starts.</p>
      </div>
      <div class="stats">
        <div class="stat"><div class="n">${DK_N1}</div><div class="l">${DK_ST1}</div></div>
        <div class="stat"><div class="n">${DK_N2}</div><div class="l">${DK_ST2}</div></div>
        <div class="stat"><div class="n">${DK_N3}%</div><div class="l">${DK_ST3}</div></div>
      </div>
    </div>
  </section>

  <section id="contact">
    <div class="wrap split">
      <div>
        <h2>Contact</h2>
        <p>Tell us what you need and roughly when. We answer enquiries the same
           working day.</p>
      </div>
      <dl class="contact">
        <dt>Email</dt><dd><a href="mailto:${DK_EMAIL}">${DK_EMAIL}</a></dd>
        <dt>Telephone</dt><dd>${DK_PHONE}</dd>
        <dt>Office hours</dt><dd>Monday to Friday, 08:30 - 17:00</dd>
      </dl>
    </div>
  </section>
</main>
HTML
)
    _decoy_page "$NX_DECOY_ROOT/index.html" "$DK_BRAND — $DK_TAG" "$body"
}

_decoy_legal() {
    local body
    body=$(cat <<HTML
<main class="wrap prose" style="padding:56px 0">
  <h1>Privacy notice</h1>
  <p>This notice explains what ${DK_BRAND} does with personal information
     collected through this website and in the course of providing services.</p>
  <h2>What we collect</h2>
  <ul>
    <li>Contact details you send us by email or give us over the telephone.</li>
    <li>Records of work carried out, quotations and invoices.</li>
    <li>Standard web server logs, kept for a short period for security purposes.</li>
  </ul>
  <h2>Why we hold it</h2>
  <p>To answer enquiries, to carry out work you have asked for, and to meet our
     accounting and tax obligations. We do not sell personal information and we
     do not use it for advertising.</p>
  <h2>How long we keep it</h2>
  <p>Enquiries that do not lead to work are deleted within twelve months.
     Records connected to work carried out are kept for seven years.</p>
  <h2>Your rights</h2>
  <p>You may ask for a copy of the information we hold about you, ask us to
     correct it, or ask us to delete it where we are not required to keep it.
     Write to <a href="mailto:${DK_EMAIL}">${DK_EMAIL}</a>.</p>
</main>
HTML
)
    _decoy_page "$NX_DECOY_ROOT/privacy.html" "Privacy notice — ${DK_BRAND}" "$body"

    body=$(cat <<HTML
<main class="wrap prose" style="padding:56px 0">
  <h1>Terms of business</h1>
  <p>These terms apply to work carried out by ${DK_BRAND} unless we have
     signed a separate written agreement with you.</p>
  <h2>Quotations</h2>
  <p>Quotations are valid for thirty days and are based on the information
     available at the time. If the scope changes we will tell you before
     carrying out additional work.</p>
  <h2>Payment</h2>
  <p>Invoices are payable within thirty days of the invoice date. We reserve
     the right to charge statutory interest on overdue accounts.</p>
  <h2>Liability</h2>
  <p>Nothing in these terms limits liability for death or personal injury
     caused by negligence, or for fraud. Otherwise our liability is limited to
     the value of the work in question.</p>
  <h2>Cancellation</h2>
  <p>Either party may cancel scheduled work with five working days notice.
     Costs already committed on your behalf remain payable.</p>
</main>
HTML
)
    _decoy_page "$NX_DECOY_ROOT/terms.html" "Terms of business — ${DK_BRAND}" "$body"
}

_decoy_static() {
    cat > "$NX_DECOY_ROOT/robots.txt" <<'ROBOTS'
User-agent: *
Allow: /
ROBOTS
    tpl_render "$NX_DECOY_ROOT/favicon.svg" ACCENT "$DK_ACCENT" INITIAL "$DK_INITIAL" <<'TPL'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <rect width="64" height="64" rx="14" fill="@@ACCENT@@"/>
  <text x="32" y="43" text-anchor="middle" font-family="Segoe UI, Arial, sans-serif"
        font-size="34" font-weight="700" fill="#ffffff">@@INITIAL@@</text>
</svg>
TPL
}

# decoy_generate [force] — при повторном запуске сайт не пересобирается,
# иначе домен на глазах у наблюдателя менял бы нишу и название.
decoy_generate() {
    local force=${1:-0}
    if [[ -s "$NX_DECOY_ROOT/index.html" && -n $(state_get DECOY_BRAND) && $force != 1 ]]; then
        ok "прикрытие на месте: $(state_get DECOY_BRAND) [$(state_get DECOY_KIND)]"
        return 0
    fi

    local -a radii=(4px 8px 12px 2px)
    local -a mailbox=(hello enquiries office info contact)

    decoy_pick_niche
    DK_BRAND="$(rand_pick DECOY_FIRST) $DK_SECOND"
    DK_INITIAL=${DK_BRAND:0:1}
    DK_FONT=$(rand_pick DECOY_FONTS)
    DK_RADIUS=$(rand_pick radii)
    IFS='|' read -r DK_ACCENT DK_ACCENT_DARK DK_BG DK_SURFACE DK_BORDER DK_TEXT DK_MUTED \
        <<< "$(rand_pick DECOY_PALETTES)"

    DK_YEAR=$(( 1979 + RANDOM % 38 ))
    DK_N1=$(( 3 + RANDOM % 12 ))
    DK_N2=$(( 140 + RANDOM % 8600 ))
    DK_N3=$(( 92 + RANDOM % 8 ))
    DK_EMAIL="$(rand_pick mailbox)@${DECOY_DOMAIN}"
    # 020 7946 0xxx — диапазон, зарезервированный Ofcom для вымышленных номеров.
    DK_PHONE="+44 20 7946 0$(printf '%03d' $(( RANDOM % 1000 )))"

    mkdir -p "$NX_DECOY_ROOT/assets"
    _decoy_css
    _decoy_index
    _decoy_legal
    _decoy_static
    chown -R www-data:www-data "$NX_DECOY_ROOT" 2>/dev/null || true

    state_set DECOY_BRAND "$DK_BRAND"
    state_set DECOY_KIND  "$DK_KIND"
    ok "сгенерировано прикрытие: $DK_BRAND [$DK_KIND], основано в $DK_YEAR"
}
