/* Galla engine tests — run with: node engine.test.js
   Needs engine.js and app_data.json beside it (source bundle). 83 assertions. */
const E = require('./engine.js');
const raw = require('./app_data.json');
const A = E.analyse(raw);
let pass = 0, fail = 0;
const ok = (name, cond, extra) => { if (cond) { pass++; } else { fail++; console.log('  FAIL', name, extra === undefined ? '' : extra); } };
const near = (a, b, tol) => Math.abs(a - b) <= (tol === undefined ? 0.01 : tol);

console.log('— engine unit tests');
// churn: every lost customer is past the lost cut-off, every active one is inside it
A.lost.forEach(c => ok('lost past cut-off ' + c.name, c.daysSince >= Math.max(18, 2.5 * c.avgGap)));
A.loyal.forEach(c => ok('loyal inside risk cut-off ' + c.name, c.daysSince < Math.max(6, 1.7 * c.avgGap)));
ok('lost and at-risk do not overlap', A.lost.every(c => A.atRisk.indexOf(c) < 0));
ok('monthly value = basket x visits/month', A.lost.every(c => near(c.monthlyValue, c.avgBasket * c.visitsPerMonth, 0.5)));

// days of cover
ok('cover = stock / perDay', A.inv.every(x => x.perDay === 0 || near(x.coverDays, x.stock / x.perDay, 0.001)));
ok('critical means under 2 days', A.inv.filter(x => x.status === 'critical').every(x => x.coverDays < 2));
ok('overstock means over 21 days', A.inv.filter(x => x.status === 'over').every(x => x.coverDays > 21));
ok('perishables get a 2-day reorder', A.inv.filter(x => ['Dairy','Bakery','Fresh'].includes(x.category) && x.perDay > 0)
  .every(x => x.suggestQty === Math.max(1, Math.ceil(x.perDay * 2))));

// udhaar aging
const b = A.money.buckets;
ok('aging buckets sum to receivables', near(b.b0 + b.b1 + b.b2 + b.b3, A.kpis.recvTotal, 1));
ok('over-30 equals b2 + b3', near(b.b2 + b.b3, A.kpis.overdue30, 1));
ok('every receivable is bucketed', A.money.recv.every(r => r.days >= 0));

// enquiry ranking
ok('enquiry list is sorted by score', A.enq.every((x, i) => i === 0 || A.enq[i - 1].score >= x.score));
ok('rank is 1..n', A.enq.every((x, i) => x.rank === i + 1));
ok('waitlist covers every enquiry', A.waitlist.length === A.enq.length);
ok('waitlist entries are chronological', A.waitlist.every(w => w.entries.every((e, i) => i === 0 || w.entries[i - 1].day <= e.day)));

// dealer cost
ok('best dealer is cheapest after discount', A.money.deals.every(d => d.best.eff <= d.worst.eff));
ok('deal saving is never negative', A.money.deals.every(d => d.save >= 0));
ok('dealer wins count every deal once', A.money.dealerRank.reduce((s, d) => s + d.wins, 0) === A.money.deals.length);

// plan
ok('plan is ordered by impact', A.plan.every((p, i) => i === 0 || A.plan[i - 1].impact >= p.impact));

console.log('— golden routing set (en / hi / te / romanised)');
const GOLD = [
  ['aaj ka sales kitna hua', 'sales_today'],
  ['sales entha hua', 'sales_today'],
  ['ఈరోజు అమ్మకాలు ఎంత', 'sales_today'],
  ['week me sales kam kyun', 'sales_week'],
  ['kaunse customer aa nahi rahe', 'lost_customers'],
  ['grahak ravatledu', 'lost_customers'],
  ['कौन से ग्राहक आना बंद कर चुके हैं', 'lost_customers'],
  ['kya stock karna chahiye', 'stock_gap'],
  ['stock ledu em cheyali', 'stock_gap'],
  ['ఏమి స్టాక్ చేయాలి', 'stock_gap'],
  ['khatam ho raha hai kya', 'reorder'],
  ['feedback kya hai', 'feedback'],
  ['కస్టమర్లు ఏం ఫిర్యాదు చేస్తున్నారు', 'feedback'],
  ['sales kaise badhau', 'grow'],
  ['dhanda badhao', 'grow'],
  ['top items batao', 'top_items'],
  ['slow items', 'slow_items'],
  ['namaste', 'help'],
  ['hello', 'help'],
  ['kuch samajh nahi aa raha', 'fallback']
];
GOLD.forEach(([q, want]) => { const got = E.route(q); ok('route "' + q + '" → ' + want, got === want, 'got ' + got); });

console.log('— pain-point routing');
[['udhaar not coming back', 'credit'], ['appu vasoolu kavatledu', 'credit'],
 ['cash tight hai', 'cash'], ['dabbulu levu', 'cash'],
 ['grahak ravatledu', 'customers'], ['blinkit taking business', 'competition'],
 ['dealer price high', 'cost'], ['karchu ekkuva', 'cost'],
 ['dead stock lying', 'dead'], ['home delivery demand', 'delivery'],
 ['stock ledu', 'stock'], ['', 'generic']].forEach(([q, want]) => {
  const got = E.diagnose(q, A).domain; ok('pain "' + (q || '(empty)') + '" → ' + want, got === want, 'got ' + got);
});

console.log('— number consistency in generated messages');
const money = E.money;
const cases = [
  ['udhaar reminder', 'Namaste Naveen garu. ' + money(A.money.recv[0].amount) + ' is pending for ' + A.money.recv[0].days + ' days.',
    [money(A.money.recv[0].amount), A.money.recv[0].days]],
  ['today sales', 'You did ' + money(A.kpis.todayRev) + ' across ' + A.kpis.todayTxns + ' bills.',
    [money(A.kpis.todayRev), A.kpis.todayTxns]],
  ['waitlist alert', 'The Horlicks 500g you asked for is in. ' + money(238) + ' a jar.',
    [money(238)]]
];
cases.forEach(([name, text, facts]) => ok('numbers verified: ' + name, E.verifyNumbers(text, facts).ok));
ok('a wrong figure is rejected', !E.verifyNumbers('You did ₹99,999 today', [money(A.kpis.todayRev)]).ok);
ok('a wrong percentage is rejected', !E.verifyNumbers('Sales up 42%', ['-7']).ok);

console.log('— edge cases');
ok('empty diagnosis still answers', E.diagnose('', A).findings.length === 3);
ok('unknown words still answer', E.diagnose('zzzz qqqq', A).actions.length === 3);
ok('no enquiry has zero entries', A.waitlist.every(w => w.entries.length > 0));
ok('bills always carry a customer', A.recentBills.every(b => b.cid && b.phone));
ok('receivables have a status', A.money.recv.every(r => ['lost', 'at_risk', 'active', 'walkin'].includes(r.status)));

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
