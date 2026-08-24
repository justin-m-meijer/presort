# Presort

A small macOS app that reads your inbox with a language model **you** run, and turns
what it finds into calendar entries and reminders.

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

**It writes only into its own calendar and reminder list.** Your existing calendars are
read so it can spot a duplicate, and never written to.

## What it looks for

Six built-in categories, each a switch you can turn off, each with a description you can
rewrite in your own words:

| | |
|---|---|
| Appointments | somewhere you have to be, at a time |
| Things to do | something you have to act on |
| Invoices and payments | with the amount and the due date |
| Renewals and expiries | subscriptions, insurance, documents |
| Parcels to collect | waiting at a pick-up point |
| Travel and tickets | flights, trains, hotels, performances |

You can add your own. What you **cannot** change is the JSON schema wrapped around your
description, because the validation above depends on its shape. The app shows you those
fixed parts, greyed out, above and below the box you type in.

Deadlines get a reminder a configurable number of days early (three by default) while
keeping the real date as the due date. A reminder that fires on the day a parcel must be
back is not much use.

## Requirements

- macOS 14 or later
- Apple Mail, configured with the account you want scanned
- Any endpoint that speaks the OpenAI chat-completions shape: [Ollama](https://ollama.com)
  on the same Mac, a server on your network, or a hosted service if you would rather

## Building

No Xcode needed; the command line tools are enough.

```
./bouw.sh          # builds build/Voorsorteren.app
./proef.sh         # runs the tests
```

The build is ad-hoc signed, which is enough to run it yourself. Distributing it to other
people needs a Developer ID and notarisation.

On first launch it will ask for access to Calendar, Reminders and Apple Mail. All three
are required: without them there is nothing to read and nowhere to write.

## Configuration

Everything lives in Settings, nothing in the source. Point it at your model (address,
model name, optional key), tell it which Mail account and mailbox to read, and choose how
far back to look. Nothing is scanned twice.

## A note on the language

The interface and the source comments are in Dutch, because that is the language of the
mail it was written to read. The code should still be legible if you don't speak it:
`Wachtrij` is queue, `Herkenner` is detector, `Voorstel` is proposal, `Instellingen` is
settings.

## Licence

[PolyForm Noncommercial 1.0.0](LICENSE.md).

Use it, change it, fork it and share it for any noncommercial purpose: personal use, study,
hobby projects, and use by charities, schools and public institutions. Selling it, or using
it as part of something you sell, is not covered. If that is what you want, ask.
