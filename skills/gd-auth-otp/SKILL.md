---
name: gd-auth-otp
description: Use only when designing or building an email one-time-code (OTP) sign-in, from the code request through the signed-in session and the email send. Not for other login methods.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Email OTP sign-in

Load this only for a sign-in that emails a six-digit code. It is written from three reference apps that shipped this
flow. Done means a real user can sign in on the deployed app, not that the tests pass.

## What the reference apps share, and what went wrong

Common to all three: an invite-only user lookup, `202` for unknown emails, a six-digit code stored as a hash, a
10-minute expiry, an attempt limit, one open code per email, SES sent through the SDK with the node or pod role,
plain-text email, and tests with a fake mailer.

What went wrong, each one a rule below:

- The mailer defaulted to a log mailer, so the first production deploy sent no email and wrote the code to the log.
- The pod had no AWS region, so SES failed with "Missing Region" on the second deploy.
- The fake mailer passed every test, so the two configuration errors above reached production unseen.
- The code hash was a plain SHA-256 of email and code, which a leaked table lets anyone brute force in seconds.
- A failed send was logged but answered `202`, so the user got no email and nothing alerted anyone.
- The per-IP limit lived in one pod's memory, so with several replicas the real limit is
  the number of replicas times the limit.
- Only a plain-text part was sent, so no HTML part showed the code large or marked it for copying.
- The attempt limit was 5 in one design and 3 in another. Pick one value and state it in the PR.

## Access

- **Invite-only.** A code is sent only to an email that already has a user row. No endpoint creates users.
  Why: an open sign-up lets anyone create an account by typing an email, and the owner decides who gets in.
- **Always `202` with an empty body** for an unknown email, a disabled user and an invited user alike.
  Why: a different answer for known emails lets anyone list the users of the app.
- **Count rate limits for every address, known or not,** and answer `429` the same way for both.
  Why: a limit that counts only known emails tells an attacker which emails exist.
- **Limits:** at most 5 codes per email per hour and 20 requests per IP per minute, as the reference apps set them.
  Why: caps mail volume and guessing. Keep the per-email count in the database so it holds across replicas.

## The code

- **Six digits from a cryptographic random source,** zero padded (`crypto/rand`, `crypto.randomInt`).
  Why: a math random generator is predictable, and an unpadded code can drop its leading zeros.
- **Store only a keyed hash** (HMAC-SHA-256 with a server-side secret) of the email and the code. A plain hash is not
  enough for this.
  Why: a million possible codes fall to an unkeyed hash in seconds once the table leaks. The reference apps did this
  and it is the gap to close first.
- **Expires 10 minutes after issue.** Why: each minute of validity is a minute an intercepted code still works.
- **Five wrong guesses void the code, then `429` `TOO_MANY_ATTEMPTS`.** Count the attempt before comparing, in one
  conditional update (`attempts < max`).
  Why: counting after the comparison lets parallel requests guess past the limit.
- **One open code per email.** Issuing a new code retires the older open ones in the same transaction.
  Why: otherwise an earlier code from the email still signs in after the user asked for a new one.
- **Use a code once.** Set `consumed_at` only where it is still null, and check the rows affected.
  Why: two parallel requests with the right code would both sign in.
- **Wrong, expired, used and unknown codes all answer the same `401` `invalid_code`.** Why: different answers reveal
  the state of the code.

## The input

- **Six separate boxes with `input-otp`** (`OTPInput`, `REGEXP_ONLY_DIGITS`, `maxLength` 6).
  Why: one box per digit is what people expect, and the library handles paste and digit-only input.
- **`autoComplete="one-time-code"`** on the input. Why: phones and password managers then offer the code from the email.
- **Submit when the sixth digit is entered** (`onComplete`), and keep a visible Sign in button.
  Why: fewer taps for most users, and the button still serves keyboard and screen reader users.
- **Clear the boxes on a wrong code** and show the error. Why: a retyped code is cheaper than editing a wrong one.
- **Offer "Use a different email"** on the code step. Why: a typo in the email is common and should not need a reload.
- **Ignore a second submit while a request is in flight.** Why: a double submit spends an attempt for nothing.
- **Show the same text for every email:** "If {email} is invited, we emailed it a code." Why: the page must not reveal
  who is invited.

## The session

- **Opaque token:** 32 random bytes, base64url, stored only as a SHA-256 hex. Why: a database read cannot replay it.
- **Valid 30 days,** checked on every request. Why: a 30-day window keeps a phone signed in without a code each day.
- **Revoke on logout and on disable.** Logout revokes that one session; disabling a user revokes all of their sessions.
  Why: a lost device or a removed person must lose access at once, which an unrevoked JWT cannot do.
- **Do not add a short-lived JWT without a reason.** One reference app used a 15-minute JWT plus rotated refresh tokens.
  Why: one revocation model is simpler to audit, and the owner chose opaque tokens.

## Email send

- **Send through the SES API** (`sesv2.SendEmail`) with the node or pod role. No SMTP user and no SMTP password.
  Why: the role already grants send rights, and a stored SMTP secret is one more thing to rotate and to leak.
- **Pin the sender.** `MAIL_FROM` is one verified address, for example `noreply@example.com`, and the IAM policy
  allows only that address.
  Why: the role then cannot send as anyone else.
- **IAM policy on every node role that can run the pod:** `ses:SendEmail`, on the identity ARN of the domain, with
  condition `StringEquals ses:FromAddress` set to `MAIL_FROM`.
  Why: a pod can move to any node, and a send from a node without the policy fails with access denied.
- **Chart env set for every environment:** `MAILER_MODE=ses`, `MAIL_FROM`, and `AWS_REGION` set to the SES region
  (for example `ap-southeast-1`).
  Why: the mailer defaults to a log mailer when `MAILER_MODE` is missing, and a pod has no region of its own.
- **Refuse to start in production without the SES mailer.** Why: a silent fallback to the log mailer is exactly what
  sent no email on the first deploy.
- **Log one startup line with `mailer_ses` as a boolean** (no values, no secrets). Why: a reader of the logs sees
  whether email is on without guessing.
- **Multipart email:** a `text/plain` part and a `text/html` part, both always sent. Why: some clients show only text,
  and the HTML part gives the code its size.
- **Code alone on its own line** in the text part, and large monospace in the HTML part, with "It works once and
  expires in 10 minutes" and "If you did not ask for this, ignore this email." Why: copy-code and autofill features
  read a line that holds only the code.
- **Generic subject** such as "Your sign-in code". Why: subjects show on lock screens and in notifications, so the
  code belongs only in the body.
- **Schema.org JSON-LD (best effort, unverified).** Gmail's copy-code display honors markup only from senders Google
  registers and only for its documented types. No documented type for one-time codes was found. Add the markup only
  when you have verified the type, and say in the PR that it is unverified.
  Why: a hand-made block that Gmail ignores costs review time and gives false confidence.
- **Log every successful send:** the SES message id, the request id and the route. Never the code, the body or the
  address. Why: the message id is the only proof in the logs that SES accepted the mail.
- **On a failed send, log at error level** with the error text, its type, the request id and the route, then still
  answer `202`. Why: the answer must not reveal the account, so the log line is the only signal and it must be loud.
- **The log mailer is for local development only** (`MAILER_MODE=log`), and it prints the code. Why: a printed code in
  production logs is a live credential.

## Tests

- **Use a fake mailer and a fake store.** Why: tests must not call SES or the database service.
- **A fake mailer cannot catch configuration errors,** so add one unit test that production config selects SES and
  fails without `MAIL_FROM` or `AWS_REGION`. Why: all tests passed while the first two deploys failed.
- **Cover these cases:** expiry, the attempt limit to `429`, one open code per email, a used code, an unknown email
  (`202`, no send), a disabled user (`202`, no send), and revoke on logout and on disable.
  Why: these are where an OTP flow leaks accounts or lets a guess through.

## Verify after deploy

An agent can check the logs only. Read the app's production log group (for example the CloudWatch group `/<app>/prod`).

- **Expect** the startup line with `mailer_ses` true, one SES message id line after a code request, and no
  `send ... failed` line. Why: these three lines show that SES accepted the mail and that the flow reached it.
- **Say plainly that an agent cannot verify** inbox delivery, spam placement or Gmail's copy-code display. The owner
  checks these with a real inbox. Why: no agent can open a real mailbox.
- **Done means the user can use it end to end:** request a code, receive it, enter it, get a session, call the
  signed-in endpoint, log out, and see the old token fail. Why: a flow that passes tests but fails in a browser is
  not done.

## Owner steps

List these as a checklist at the end of the work, because only the owner can do them:

- [ ] Verify the sender identity in SES and confirm `MAIL_FROM`.
- [ ] Apply the IAM policy to every node role that can run the pod.
- [ ] Merge and deploy.
- [ ] Request a code with a real invited inbox and confirm the email arrives.
