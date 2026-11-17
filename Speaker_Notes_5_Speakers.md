# Speaker Notes: Digital Campus ID (5 speakers)

# Speaker 1: Introduction and problem

## Slide 1: Title

Good morning. We are presenting Digital Campus ID, a verified virtual student ID with QR gate entry. Our team is four students from VNRVJIET, guided by K. Naga Sandhya. In the next few minutes we will show the problem, how we understood the people involved, and the working prototype.

## Slide 2: TABLE OF CONTENTS

This is the outline: the problem statement, how we studied the stakeholders, the insights and point-of-view statements, ideation, then the solution prototype, feasibility and sustainability. Keep this brief and move on.

## Slide 3: Problem Statement

Our college does not let students in without a physical ID card. A forgotten, lost, damaged or not-yet-issued card means being stopped at the gate, and guards must make quick calls in a crowd. So our question is: how might we let enrolled students prove who they are at the gate without a physical card, in a way guards trust and the administration controls? Scope for now is our own students; staff, visitors and alumni come later. Be upfront that this problem comes from our own campus experience, not formal gate data.

_Hand over to the next speaker._

# Speaker 2: Understanding the users

## Slide 4: Empathy Tool Used

We used empathy maps for four stakeholders: a student, a first-year, a gate guard and an administrator, plus a stakeholder analysis. Research was secondary: digital student IDs, India's APAAR ID and data-protection law. The limitation is that we did not interview guards or administrators. Say that clearly, and say we plan to.

## Slide 5: Empathy Map 1: Student

Meet Ananya, a second-year day scholar. She forgets her card, pleads at the gate and feels embarrassed. What she wants is a backup on the phone she never leaves behind. These personas are illustrative, built from our experience and research.

## Slide 6: Empathy Map 2: Fresher

Rahul is a first-year whose card is still being made. He only has an admission receipt and knows nobody who can vouch for him. His need is a verified temporary pass from day one.

## Slide 7: Empathy Map 3: Guard

Mr. Venkat, the guard, cannot tell a real card from a copy in two seconds, and he is the one blamed if the wrong person enters. He needs a clear, fast result, not another judgement call.

## Slide 8: Empathy Map 4: Admin

Ms. Lakshmi, the administrator, handles duplicate-card lines every week. She does not want another list to maintain, and she is responsible for student data. So our system must add little work and store minimal data.

_Hand over to the next speaker._

# Speaker 3: Insights and ideation

## Slide 9: Defining Insights

We sorted the needs into primary, secondary and latent. Primary is what everyone says out loud: get in, get in fast, be sure it is the right person. Secondary is what makes that work in real conditions. Latent is the unspoken need, like not feeling embarrassed and not creating data risk.

## Slide 10: Define Point of View Statement (1/2)

Point-of-view statements one and two. Ananya needs to prove she is enrolled using her phone, because a missing piece of plastic should not cost her a lecture. Rahul needs a verified temporary pass from the first day, because he is enrolled but invisible to the gate.

## Slide 11: Define Point of View Statement (2/2)

Statements three and four. The guard needs a verified photo and name in a couple of seconds. The administrator needs one place to manage passes with minimal personal data stored.

## Slide 12: Ideation Method Used

For ideation we used SCAMPER on the campus-entry problem. Walk through two or three rows, for example substituting the plastic card with a phone, and combining the pass with the gate scan. Do not read every row.

_Hand over to the next speaker._

# Speaker 4: Solution and prototype

## Slide 13: Key Features

Here are the key features. One: sign in with your college email, which is your roll number, and verify it with a one-time code. Two: students add their details, a profile photo and an ID card photo. Three: a live QR pass that refreshes every 30 seconds, so screenshots go stale. Four: an offline gate scanner that gives a green or red result. Five: out pass, where students scan the QR before leaving, the exit is logged with their details, and only the admin can export it as CSV or Excel. Six: a long-lived pass with renewal and minimal data. Out pass is planned, so say it is the next step if asked.

## Slide 14: Solution Prototype

These are the student app screens from our prototype. First sign in with the college email and the code sent to it. Then add details and photos, including the ID card. Then the pass appears with the QR and a countdown. Mention that the QR shown is a sample and the screens are mock renders of the real layout.

## Slide 15: Solution Prototype

This is the guard's scanner. A valid pass shows a green result with the photo and name, and the guard compares the face. An invalid or expired pass shows red with advice to refresh or use the backup desk. The steps on the right explain the check: the server signs a short-lived token, the app shows it as a QR, the scanner verifies the signature offline with the public key. The system proves the pass, the guard proves the person.

## Slide 16: Technical Approach

Technical approach: the student app, written in Flutter, shows a QR carrying a credential signed by the server. The scanner app, also Flutter, checks the signature on the device with the public key, so the gate works without internet. The admin page handles the log and exports. We use ES256 signatures, CBOR encoding, a TypeScript backend on Postgres, and over 680 automated tests. The prototype runs on a local server; Supabase is the planned deployment.

_Hand over to the next speaker._

# Speaker 5: Privacy, impact and close

## Slide 17: Data Privacy and Safety

Data privacy and safety. We store only name, roll number, branch and two photos. The QR is signed with a private key that stays on the server and expires within about 45 seconds. The scanner holds only the public key, so a lost scanner cannot create passes. The student's key sits in the Android Keystore. Only the admin can export student records; guards see just the scan result. Be honest that encrypted logs, app lock and screenshot blocking are still to be added.

## Slide 18: Innovation

Desirability, viability, feasibility. Students stop being turned away, guards get a clear result, and the office gets fewer duplicate requests. It runs on phones students already own at low cost, and the college owns the data. It is built from standard parts. Assumptions to test: that the system works on ordinary phone cameras, and that the administration accepts a phone pass at the gate.

## Slide 19: Design for Environment (Optional)

Sustainability: fewer plastic cards printed, lost and reprinted, and digital passes instead of paper slips. These are small, indirect benefits, and servers and phones have their own footprint, so we frame it honestly and do not oversell it. It maps to SDG 4 and SDG 9.

## Slide 20: Mentor Interactions

Mentor interactions. Share the feedback received so far, for example the 7 October session where the empathy charts were revised. Fill in the remaining interactions before submitting.

## Slide 21: Team Experiences

Reflection. Pick one or two prompts: which assumption the empathy maps changed, especially the guard's point of view, and which tool was most useful. Close by thanking the panel and inviting questions.

_Hand over to the next speaker._

