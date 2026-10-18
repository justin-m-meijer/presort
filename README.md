<p align="center">
  <img src="docs/icon.png" alt="" width="112">
</p>

# Presort

A small macOS app that reads your inbox with a language model **you** run, and turns
what it finds into calendar entries, reminders and filed documents.

<p align="center">
  <img src="docs/flow.svg" alt="Mail passes a model you run yourself and is split into calendar entries and reminders" width="560">
</p>

Everything lands in your mailbox and then nothing happens to it: the confirmation with a
date buried in the third paragraph, the invoice due on the fourth, the parcel that has to
go back before the eleventh. A language model is good at spotting those. Every product
that offers to do it wants a copy of your mailbox on their servers first.

This one doesn't. Mail comes out of Apple Mail, goes to a model at an address you choose,
and comes back. Nothing is sent to anyone.

## How it works

```
Apple Mail  ->  your model  ->  the app checks  ->  you approve  ->  its own calendar
                (no tools,       (title length,      (or let it        (never your
                 JSON only)       date sanity)        file itself)      existing ones)
```

**The model gets no tools.** It receives text and must answer with JSON in a fixed shape.
It cannot call anything, write anything or reach anything. An instruction hidden inside an
email can therefore produce a wrong form at worst, never an action.

**The app checks the answer instead of trusting it.** Titles must be 2–120 characters.
Dates must fall between roughly a month back and a year ahead. An appointment longer than
48 hours is refused. Whatever survives goes into a queue.

**It writes into a calendar and a reminder list of its own.** Your existing calendars are
read so it can spot a duplicate, and left alone. There is a switch to point it at a calendar
you already use, with the reason not to next to it.

Everything the app does happens on your Mac, with one exception you have to turn on
yourself: a **connection** to a service elsewhere. Paperless-ngx takes a found document;
[Parcel](https://parcelapp.net) takes a tracking number.

## What it looks for

Eight built-in categories, each a switch you can turn off, each with a description you can
rewrite in your own words:

| | | lands in |
|---|---|---|
| Appointments | somewhere you have to be, at a time | calendar |
| Things to do | something you have to act on | reminders |
| Invoices and payments | with the amount and the due date | reminders |
| Renewals and expiries | subscriptions, insurance, documents | reminders |
| Parcels to collect | waiting at a pick-up point | reminders |
| Parcels on their way | a shipping notice with a tracking number | Parcel, and a reminder on the day |
| Travel and tickets | flights, trains, hotels, performances | calendar |
| Documents worth keeping | an attached invoice, statement, policy or ticket | Paperless-ngx |

A document only gets asked about when the message actually carries an attachment, and it
goes to Paperless with what the mail already says about it: the sender as correspondent,
the date printed on it, and a title. Tags are matched against ones that already exist in
your archive; none are invented.

A parcel is only proposed when its tracking number appears in the mail itself, and only
once, however many mails the shop and the carrier send about it. The carrier is matched
against Parcel's own list; when a mail just says "DPD" and that fits several, the card asks
which one. Parcel allows twenty additions a day through its API, refused ones included, and
only with Premium, so the app keeps count as well. The first fifteen a day go in by
themselves (you can change the number), which leaves the rest for the button. On the day a
parcel is expected, a reminder comes up with the tracking number in it; when the mail gives
no day, the reminder follows once Parcel knows. Parcel has no way to remove a delivery, so
this is the one thing the app files that cannot be undone.

You can add your own. What you **cannot** change is the JSON schema wrapped around your
description, because the validation above depends on its shape. The app shows you those
fixed parts, greyed out, above and below the box you type in.

Deadlines get a reminder a configurable number of days early (three by default) while
keeping the real date as the due date. A reminder that fires on the day a parcel must be
back is not much use.

## What it looks like

<p align="center">
  <img src="docs/screenshot-waiting.png"
       alt="Three proposals waiting: a dental appointment going to the calendar, an energy bill going to the reminder list, and an attached statement going to Paperless-ngx. Each card lists the fields that will be written."
       width="760">
</p>

Example data. Each card shows what will be written, not the fragment of mail it came from,
and each shape has a colour that follows it into the list of what has been handled.

<p align="center">
  <img src="docs/screenshot-welcome.png" alt="The welcome screen, explaining that mail goes to a model at an address you choose and that nothing is sent anywhere else." width="620">
</p>

## Requirements

- macOS 14 or later
- Apple Mail, configured with the account you want scanned
- Any endpoint that speaks the OpenAI chat-completions shape: [Ollama](https://ollama.com)
  on the same Mac, a server on your network, or a hosted service if you would rather

## Building

No Xcode needed; the command line tools are enough.

```
./build.sh         # builds build/Presort.app
./test.sh          # runs the tests
```

The build is ad-hoc signed, which is enough to run it yourself. Distributing it to other
people needs a Developer ID and notarisation.

On first launch it will ask for access to Calendar, Reminders and Apple Mail. All three
are required: without them there is nothing to read and nowhere to write.

## Configuration

Everything lives in Settings, nothing in the source. Point it at your model (address,
model name, optional key), tell it which Mail account and mailbox to read, and choose how
far back to look. Nothing is scanned twice.

Settings › Model can test the model you chose, or every model the endpoint lists. Each gets
one short, made-up message, never your mail, and the answer is checked the way a real one
would be. A model that spends its whole answer thinking is caught there; when the server
lets thinking be switched off per request, the test does that for you. The same check runs
when the app starts, when you change the model, and after a run in which no answer could be
used, and the main window says so when the model is not up to the work.

## Languages

The interface, the six descriptions and the prompt frame around your mail ship in English,
Dutch, French and German, and follow whatever language your Mac is set to. The French and
German translations have not been checked by a native speaker yet.

The language matters more than usual here, because the frame around your description is
also what tells the model which language to answer in — so a French Mac gets French
reminders, not translated ones.

The source, its comments and everything on GitHub are in English.

## Support

If this is useful to you, you can support my work with a [donation through PayPal](https://www.paypal.com/donate?hosted_button_id=UNBDNLN8MSC88).

## Licence

Licensed under the [Mozilla Public License 2.0](LICENSE). You may use, change and share it, also
commercially. If you distribute a changed version of these files, those files must stay under the
MPL 2.0 and their source must be available.
