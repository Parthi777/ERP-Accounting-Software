/**
 * The process guide — one source, two renderings.
 *
 * Written for someone on their first week who has been shown the login and
 * nothing else. It is data rather than a page so the same words appear in the
 * browser (/help) and in the PDF (/api/documents/process-guide) — a printed
 * handbook that has drifted from the screen is worse than none, because it is
 * believed.
 *
 * `navPaths` is what makes the Help button contextual: the header matches the
 * current route against these and opens the guide at the matching section.
 */

export interface GuideStep {
  /** Imperative, one action. */
  readonly text: string;
  /** Why it matters, or what people get wrong. Optional. */
  readonly note?: string;
}

export interface GuideSection {
  /** Anchor in the page, and bookmark in the PDF. */
  readonly id: string;
  readonly title: string;
  /** Which roles do this. */
  readonly who: string;
  /** Where it lives in the sidebar. */
  readonly where?: string;
  /** One or two sentences on what this is for. */
  readonly why: readonly string[];
  readonly steps?: readonly GuideStep[];
  /** The mistakes that cost time, or money, or a statutory record. */
  readonly watchOut?: readonly string[];
  /** Route prefixes this section explains. */
  readonly navPaths?: readonly string[];
}

export const GUIDE_TITLE = 'How this system is used';
export const GUIDE_SUBTITLE =
  'A working guide to the day-to-day processes, for anyone new to the dealership';

export const GUIDE_SECTIONS: readonly GuideSection[] = [
  {
    id: 'shape',
    title: 'The shape of the system',
    who: 'Everyone, before anything else',
    why: [
      'This is an accounting system with a showroom attached, not a billing screen with '
        + 'accounts bolted on. Almost everything you do ends as an entry in the books, and '
        + 'that is what makes the reports, the GST returns and the day-end cash figure agree '
        + 'with each other.',
      'Three ideas explain most of the behaviour you will meet.',
    ],
    steps: [
      {
        text: 'Nothing is real until it is posted.',
        note:
          'A draft invoice is not a sale. It is in no ledger, no GST return and no stock '
          + 'movement, and the vehicle behind it counts as neither sold nor available. A sale '
          + 'you leave in draft is work nobody has done yet, however complete the screen looks.',
      },
      {
        text: 'Once something is posted, it is never edited — it is reversed.',
        note:
          'A posted entry is a statutory record. If it is wrong, you reverse it with a stated '
          + 'reason and enter it again correctly. Both the mistake and the correction stay '
          + 'visible, which is the point: an audit can follow what happened.',
      },
      {
        text: 'The system records history, not just the present.',
        note:
          'Prices are dated, so an invoice from last month keeps the price that applied last '
          + 'month even after a price rise. Stock movements are a ledger, not a number that '
          + 'gets overwritten. You can always ask "what did this look like then".',
      },
    ],
    watchOut: [
      'If a screen refuses to do something, read the message — it names the reason and usually '
        + 'the record to fix. The refusals are deliberate, not faults.',
    ],
  },

  {
    id: 'orientation',
    title: 'Finding your way around',
    who: 'Everyone',
    why: [
      'The sidebar is grouped by what you are at the machine to do rather than alphabetically: '
        + 'Daily operation, Stock control, Money, Insight, Setup. You will only see the sections '
        + 'your role is allowed to use, so your sidebar may be shorter than a colleague’s.',
    ],
    steps: [
      {
        text: 'Press Ctrl+K (or ⌘K) anywhere to jump to a screen by name.',
        note: 'Faster than the sidebar once you know what a screen is called.',
      },
      {
        text: 'Check the header before you enter anything.',
        note:
          'It shows the dealer, the financial year and the branch you are working in. Entries '
          + 'are recorded against the branch shown there, so switch it before you start rather '
          + 'than after.',
      },
      {
        text: 'Read the "Needs attention" panel at the top of the Dashboard.',
        note:
          'It lists what is waiting: sales still in draft, sales waiting on Accounts, approved '
          + 'invoices not yet posted, vehicles not yet delivered, cash days nobody counted. If '
          + 'a row is there, someone has to act on it. It is not bounded by the financial year '
          + '— old unfinished work stays visible until it is finished.',
      },
    ],
    navPaths: ['/dashboard'],
  },

  {
    id: 'roles',
    title: 'Who does what',
    who: 'Managers, and anyone wondering why a screen is missing',
    why: [
      'Permissions are attached to what you do, not to seniority. If you cannot see a screen, '
        + 'your role does not include that job — ask a manager rather than sharing a login. '
        + 'Two people sharing an account destroys the audit trail, which is the one thing that '
        + 'cannot be rebuilt afterwards.',
    ],
    steps: [
      {
        text: 'Sales Executive — customers, bookings, preparing a sale.',
        note: 'Can see availability and selling prices. Cannot see cost or margin.',
      },
      {
        text: 'Cashier — customers, bookings, receipts, cash book.',
        note:
          'Sees the selling price and what the customer owes. Cost, margin and profit are not '
          + 'hidden from the screen — they are never sent to it.',
      },
      {
        text: 'Counter Sales — selling accessories and spares over the counter.',
        note: 'Sales → Counter Sales, plus taking the receipt for it.',
      },
      { text: 'Service Advisor — job cards, service billing, collecting service payment.' },
      {
        text: 'Accounts — verifying and approving sales, posting, the books, GST, banking.',
        note: 'Sees purchase cost and margin, because it is their job to check them.',
      },
      { text: 'Dealer Owner — everything above, plus profitability and all branches.' },
    ],
    navPaths: ['/admin/roles', '/admin/users'],
  },

  {
    id: 'customers',
    title: 'Customers',
    who: 'Sales Executive, Cashier, Service Advisor, Counter Sales',
    where: 'Customers → Customer Master',
    why: [
      'Every sale, booking, job card and receipt hangs off a customer record, so this is usually '
        + 'the first thing you create. The customer ID is issued by the system — you never '
        + 'type one.',
    ],
    steps: [
      { text: 'Search first, by mobile number.', note: 'Creating a second record for the same person splits their history and their outstanding balance across two ledgers.' },
      { text: 'If they are new: Customers → Customer Master → New customer.' },
      {
        text: 'Enter the mobile number carefully.',
        note: 'It is how everyone will find this customer again, and the system will not allow the same number twice.',
      },
      {
        text: 'Fill in address, city, state and pincode.',
        note:
          'These feel optional and are not. An e-invoice cannot be filed without the buyer’s '
          + 'pincode and state, and the state decides which GST applies.',
      },
      {
        text: 'Enter the GSTIN only if the buyer is a registered business.',
        note:
          'It changes the invoice and it is what makes an e-invoice possible. Never type a GSTIN '
          + 'you have not seen on a document.',
      },
    ],
    watchOut: [
      'Bulk arrivals go through Customers → Import Customers rather than one form at a time. '
        + 'A file with any bad row imports nothing — fix the row and upload again.',
    ],
    navPaths: ['/customers'],
  },

  {
    id: 'booking',
    title: 'Taking a booking',
    who: 'Cashier, Sales Executive',
    where: 'Bookings → New Booking',
    why: [
      'A booking holds a model for a customer and records the advance they have paid. The advance '
        + 'is the customer’s money until the vehicle is invoiced, so the books treat it as '
        + 'something owed to them rather than as income.',
    ],
    steps: [
      { text: 'Find or create the customer.' },
      { text: 'Bookings → New Booking. Choose the model and variant.' },
      { text: 'Enter the booking amount and how it was paid.' },
      {
        text: 'Save. A booking number and a receipt are issued together.',
        note: 'Give the customer the receipt. It is their proof of the advance.',
      },
      {
        text: 'Later, convert the booking into a sale when the vehicle is allocated.',
        note: 'The advance carries across automatically and reduces what the customer still owes.',
      },
    ],
    watchOut: [
      'An open booking sits in "Needs attention" on the Dashboard until it becomes a sale or is '
        + 'cancelled. A booking nobody converted is a customer waiting.',
      'Refunding an advance is Bookings → Booking Advances, not a cash payment typed by hand '
        + '— the refund has to be tied to the booking it reverses.',
    ],
    navPaths: ['/bookings'],
  },

  {
    id: 'vehicle-sale',
    title: 'Selling a vehicle, start to finish',
    who: 'Sales Executive and Cashier prepare it; Accounts verify, approve and post',
    where: 'Sales → Vehicle Sales',
    why: [
      'This is the longest process in the system and the one worth learning properly. It is '
        + 'deliberately several steps, because the person who prepares an invoice should not be '
        + 'the only person who checks it before it becomes a statutory document.',
      'A sale moves through six states: Draft, Submitted, Accounts verification, Approved, '
        + 'Posted, Delivered. It only becomes a sale in the books at Posted.',
    ],
    steps: [
      {
        text: 'Sales → Vehicle Sales → New sale. Choose the customer and the chassis.',
        note:
          'Stock is tracked per physical vehicle, so you are choosing one specific machine by '
          + 'chassis number, not a model and a quantity.',
      },
      {
        text: 'The invoice is filled in from the price template. Check it.',
        note:
          'Ex-showroom, insurance, registration, forwarding and any accessories come from the '
          + 'price list in force on the invoice date. Adjust the lines if this deal differs.',
      },
      {
        text: 'Press Submit for verification.',
        note:
          'This is the step most often forgotten. Until you press it the invoice is a draft and '
          + 'nothing has happened — no ledger entry, no GST, and the vehicle is still shown '
          + 'as available to your colleagues.',
      },
      {
        text: 'Accounts: Begin verification, then check the sale against the deal.',
        note:
          'Customer, chassis, price, tax, accessories, payment and finance. The screen shows the '
          + 'accounting entries the system will post, side by side with what was entered.',
      },
      { text: 'Accounts: Approve — or Return for correction with a reason.' },
      {
        text: 'Accounts: Post.',
        note:
          'This is the moment the sale exists. The invoice number becomes a tax invoice, revenue '
          + 'and GST are recorded, the vehicle leaves stock and its cost becomes cost of sales. '
          + 'After this the invoice cannot be edited — only reversed.',
      },
      {
        text: 'Record what the customer paid, and any finance.',
        note: 'Cash goes to the cash book, a transfer to the bank book, finance to the finance company’s ledger.',
      },
      {
        text: 'Deliver the vehicle when it is handed over.',
        note:
          'Delivery is a separate step from posting because invoicing and handover often happen '
          + 'on different days. Until you record it, the Dashboard shows the vehicle as still owed '
          + 'to the customer.',
      },
    ],
    watchOut: [
      'If the customer is a registered business, file the e-invoice before the vehicle leaves. '
        + 'For an ordinary retail buyer there is no e-invoice to file.',
      'A vehicle going to another state needs an e-way bill travelling with it.',
      'Posted the wrong invoice? Do not try to edit it. Reverse it, with a reason, and raise a '
        + 'fresh one.',
    ],
    navPaths: ['/sales'],
  },

  {
    id: 'counter-sale',
    title: 'Selling accessories and spares over the counter',
    who: 'Counter Sales, Service Advisor',
    where: 'Sales → Counter Sales',
    why: [
      'A walk-in buying a helmet, a floor mat or a spare part. Same screen for both accessories '
        + 'and spares — the line type tells the system which it is.',
    ],
    steps: [
      { text: 'Sales → Counter Sales → new invoice. A customer is optional for a cash sale.' },
      { text: 'Add a line per item, choosing Spare part or Accessory, and the quantity.' },
      {
        text: 'Check the stock it drew from.',
        note:
          'Local stock is consumed before company stock, and the invoice shows which was used. '
          + 'That split matters to the accounts, so do not hide it or override it without reason.',
      },
      { text: 'Post the invoice, then take the payment.' },
    ],
    watchOut: [
      'If stock is short the invoice will refuse rather than go negative. Count the shelf — '
        + 'if the figure is genuinely wrong, it is a stock adjustment, which Accounts records with '
        + 'a reason.',
    ],
    navPaths: ['/inventory/counter-sales'],
  },

  {
    id: 'service',
    title: 'Service and job cards',
    who: 'Service Advisor',
    where: 'Service → Job Cards',
    why: [
      'A job card is the workshop’s record of a vehicle in for work. It becomes a service '
        + 'invoice when the work is done and priced.',
    ],
    steps: [
      { text: 'Find the customer, then the vehicle. Create the job card with the odometer reading.' },
      { text: 'Work is done. Go to Service → Service Billing and open the job card.' },
      {
        text: 'Add labour, spares and any accessories fitted.',
        note: 'Spares come out of stock as you add them, so the parts shelf and the invoice agree.',
      },
      { text: 'Post the invoice, then collect payment.' },
    ],
    watchOut: [
      'The service history stays attached to the customer and the vehicle, so the next advisor '
        + 'can see what was done last time. It is only as good as what you type into the job card.',
    ],
    navPaths: ['/service'],
  },

  {
    id: 'purchases',
    title: 'Receiving stock',
    who: 'Accounts',
    where: 'Purchases → New Purchase Bill',
    why: [
      'A purchase bill is what puts bought stock on the books — vehicles by chassis, '
        + 'accessories and spares by quantity — and records what is owed to the supplier.',
    ],
    steps: [
      { text: 'Purchases → New Purchase Bill. Choose the supplier and enter their bill number and date.' },
      { text: 'Add the lines. Vehicles are entered by chassis and engine number.' },
      {
        text: 'Check the GST on the bill.',
        note: 'Input tax recorded here is what you will claim, so it has to match the supplier’s document.',
      },
      { text: 'Post the bill. Stock appears, and the supplier ledger shows the amount payable.' },
    ],
    watchOut: [
      'A large first load of vehicles goes through Vehicles → Stock Upload from a spreadsheet '
        + 'rather than one bill line at a time. Duplicate chassis numbers are rejected before '
        + 'anything is imported.',
      'Sending stock back is Purchases → Purchase Returns, which raises a debit note. Do not '
        + 'delete the original bill.',
    ],
    navPaths: ['/purchases'],
  },

  {
    id: 'cash-book',
    title: 'The cash book, and closing the day',
    who: 'Cashier, Accounts',
    where: 'Cash Book',
    why: [
      'Every branch has one cash account and every rupee through the drawer belongs in it. '
        + 'Closing the day is not optional: it is the check that what the system thinks is in the '
        + 'drawer is what is actually there.',
    ],
    steps: [
      { text: 'Receipts and payments are recorded as they happen — most arrive automatically from sales and service.' },
      { text: 'At the end of the day open Cash Book → Day Close.' },
      {
        text: 'Read the expected closing figure: opening, plus receipts, less payments.',
      },
      {
        text: 'Count the drawer and enter the physical cash.',
        note: 'Count first, then enter. Entering the expected figure without counting makes the whole exercise pointless.',
      },
      {
        text: 'The difference is shown. Close the day.',
        note:
          'A difference is not a disaster — an unexplained one that nobody looked at is. '
          + 'Investigate it the same day, while people still remember.',
      },
    ],
    watchOut: [
      'After a day is closed it cannot be edited. A correction is an adjustment with a reason, '
        + 'and needs permission.',
      'A day with money on it and no closing shows in "Needs attention" until someone counts it.',
    ],
    navPaths: ['/cash-book'],
  },

  {
    id: 'bank',
    title: 'Banking and reconciliation',
    who: 'Accounts',
    where: 'Bank',
    why: [
      'The bank book is what the dealer’s own records say; the statement is what the bank '
        + 'says. Reconciliation is the process of making the difference explainable.',
    ],
    steps: [
      { text: 'Bank → Bank Accounts → New bank account, once per account the dealer banks through.' },
      {
        text: 'Enter the opening balance as at the day before you started using this system.',
        note:
          'It is posted to the books, not just stored, so the bank book and the trial balance '
          + 'start out agreeing. Leave it at zero if the account starts empty.',
      },
      { text: 'Receipts and payments by transfer, cheque or card are recorded in Bank → Bank Book.' },
      { text: 'Import the statement: Bank → Statement Import.' },
      {
        text: 'Match the lines: Bank → Reconciliation.',
        note:
          'The system suggests matches on amount, date and reference. Nothing is marked '
          + 'reconciled without recording what it was matched against.',
      },
    ],
    navPaths: ['/bank'],
  },

  {
    id: 'gst',
    title: 'GST, e-invoice and e-way bill',
    who: 'Accounts',
    where: 'GST',
    why: [
      'The GST screens read the invoices you have already posted. They do not recalculate '
        + 'anything, which is why the returns agree with the books.',
    ],
    steps: [
      { text: 'GST → GST Summary shows output and input tax for the period.' },
      {
        text: 'GST → E-Invoice lists posted invoices and whether each has been filed.',
        note:
          'Only invoices to a buyer with a GSTIN can be filed. A retail sale to an individual has '
          + 'no e-invoice — the screen says so on the row rather than letting you try.',
      },
      {
        text: 'File the invoice. The portal returns an IRN, which is stored against it.',
        note:
          'If the portal is down or refuses, the invoice stays posted and correct and the filing '
          + 'is marked failed. Retry it from the same screen. A portal problem never damages the '
          + 'accounts.',
      },
      { text: 'GST → E-Way Bill for goods that have to travel, typically between states.' },
    ],
    watchOut: [
      'A failed filing appears in "Needs attention". Clear it before the vehicle or the goods move.',
    ],
    navPaths: ['/gst'],
  },

  {
    id: 'period-end',
    title: 'Month end and year end',
    who: 'Accounts, Dealer Owner',
    where: 'Accounting, Reports',
    why: [
      'The books are continuous, so month end is mostly checking rather than a procedure. The '
        + 'checks below catch the things that quietly go wrong.',
    ],
    steps: [
      { text: 'Every cash day closed, and any differences explained.' },
      { text: 'Every bank account reconciled to its statement.' },
      { text: 'Accounting → Trial Balance balances.' },
      { text: 'No sales left in draft, awaiting approval, or approved and unposted.' },
      { text: 'No e-invoice left failed.' },
      { text: 'Review Reports → Margin and Reports → Branch Performance.' },
      {
        text: 'Before 1 April, ask Accounts to open the new financial year.',
        note:
          'Document numbers and the books are organised by financial year. The year selector in '
          + 'the header lets you look back at an earlier year once it exists.',
      },
    ],
    navPaths: ['/accounting', '/reports'],
  },

  {
    id: 'mistakes',
    title: 'When something is wrong',
    who: 'Everyone',
    why: [
      'How you fix a mistake depends entirely on whether it has been posted. This is the single '
        + 'most useful thing to know.',
    ],
    steps: [
      {
        text: 'Not yet posted? Edit it, or cancel it with a reason.',
        note: 'Drafts and unapproved documents are still working papers.',
      },
      {
        text: 'Already posted? It is reversed, never edited.',
        note:
          'Accounting → Journal Entries, find the entry, reverse it with a reason, then enter '
          + 'the correct version. The original stays visible. That is deliberate.',
      },
      {
        text: 'Stock figure wrong? A stock adjustment with a reason, by Accounts.',
        note: 'Never quietly retype a quantity — every movement is a traceable entry.',
      },
      {
        text: 'Not sure? Ask before posting.',
        note:
          'An unposted mistake takes a minute to fix. A posted one takes a reversal, a fresh '
          + 'document and an explanation.',
      },
    ],
    watchOut: [
      'Everything you do is recorded against your login in Administration → Audit Logs. That '
        + 'is there to protect you as much as anyone: it shows what you did and what you did not.',
    ],
    navPaths: ['/accounting/journals'],
  },
];

/** The section that explains a given route, for the contextual Help link. */
export function guideSectionFor(pathname: string): GuideSection | null {
  let best: GuideSection | null = null;
  let bestLength = 0;

  for (const section of GUIDE_SECTIONS) {
    for (const prefix of section.navPaths ?? []) {
      // Longest prefix wins, so /inventory/counter-sales beats /inventory.
      if (pathname.startsWith(prefix) && prefix.length > bestLength) {
        best = section;
        bestLength = prefix.length;
      }
    }
  }
  return best;
}
