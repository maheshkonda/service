# Onboarding Portal - UI test steps (task 115314)

Run these on the remote machine against the Docker demo. Each step lists the URL, what to do, and what you
should see. Steps marked [SCREENSHOT] are evidence for the ticket: save them as 01-health.png, 02-login.png, ...

## URLs

| What | URL |
|---|---|
| Portal (sign in) | http://localhost:4200/login |
| Dashboard | http://localhost:4200/dashboard |
| User management (admin only) | http://localhost:4200/admin/users |
| API health (liveness) | http://localhost:5000/health |
| API health (readiness, includes the database) | http://localhost:5000/health/ready |
| Swagger (API documentation and testing) | http://localhost:5000/swagger |

## Demo accounts

The start script prints the passwords at the end ("Demo sign-in"). They are also in
`C:\Cloned Repositories\tto-onboarding-portal-service\.env` (lines ending in `_PASSWORD`).

| Username | Role | Can do |
|---|---|---|
| demo.requester | Requester | Create requests, see only their own requests |
| demo.manager | Onboarding Manager | See all requests, change request status; cannot create requests |
| demo.admin | Administrator | Manage users and roles only; sees no requests |

Tip: use a private (InPrivate) browser window, and close it between users, so each sign-in starts clean.

---

## 0. Start the demo

1. Open PowerShell and run:
   ```powershell
   cd "C:\Cloned Repositories\onboarding portal"
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\start-onboarding-demo-docker.ps1 -WorkDir "C:\Cloned Repositories"
   ```
2. Wait until it says `[OK] demo verified` (the first run builds the images and takes several minutes).
3. Copy the three usernames and passwords it prints at the end.

Expected: every line shows `[PASS]`. If something shows `[FAIL]`, stop and send the output.

---

## A. Ticket acceptance criteria

### A1. API health endpoint responds [SCREENSHOT]
1. Open http://localhost:5000/health/ready
2. Expected: the page shows `Healthy`.

### A2. Sign-in page loads [SCREENSHOT]
1. Open http://localhost:4200/login
2. Expected: "SDT Onboarding Portal" sign-in page with Username, Password and a Sign in button.

### A3. A local user can sign in [SCREENSHOT]
1. On http://localhost:4200/login enter Username `demo.requester` and its password, click **Sign in**.
2. Expected: you land on http://localhost:4200/dashboard ("Onboarding Dashboard"), the header shows
   "API: healthy" and a **Log out** button.

### A4. The user can open a request [SCREENSHOT]
1. On the dashboard, click the request named **Deployment check** (created by the start script).
2. Expected: the request details page opens (URL http://localhost:4200/requests/<id>) and shows the name,
   type "New asset", status "Draft" and stage "Intake".
3. Click **Back to dashboard**.

### A5. A request is still there after the next deployment [SCREENSHOT]
1. Note the requests on the dashboard (or create one first, see C1).
2. In PowerShell run:
   ```powershell
   .\start-onboarding-demo-docker.ps1 -WorkDir "C:\Cloned Repositories" -Stop
   .\start-onboarding-demo-docker.ps1 -WorkDir "C:\Cloned Repositories" -NoBuild
   ```
3. Expected: the script shows `[PASS] Request from an earlier run still present`.
4. Sign in again at http://localhost:4200/login as `demo.requester`.
5. Expected: the same requests are still listed on the dashboard.

---

## B. Sign-in and security

### B1. Wrong password
1. At http://localhost:4200/login enter `demo.requester` with a wrong password, click **Sign in**.
2. Expected: an error message; you stay on the sign-in page.

### B2. Pages need sign-in
1. Sign out (or use a new private window), then open http://localhost:4200/dashboard directly.
2. Expected: you are sent back to the sign-in page.

### B3. Log out
1. Sign in as `demo.requester`, then click **Log out** (top right).
2. Expected: back on the sign-in page. Pressing the browser Back button does not show the dashboard again.

### B4. Requester cannot open user management
1. Signed in as `demo.requester`, open http://localhost:4200/admin/users
2. Expected: the page does not open (you are redirected), and there is no **User management** link in the header.

---

## C. Create requests (signed in as demo.requester)

### C1. New Asset [SCREENSHOT]
1. On http://localhost:4200/dashboard, in the **New Asset** card click **Start**.
2. Fill in: Asset Name, Description, Requestor, Asset Owner, Team (pre-filled "SDT"), Target date,
   Estimated Number of Services Hosted in This Asset (e.g. 2), and tick at least one environment (e.g. DEV).
3. Click **Create request**.
4. Expected: "Request <id> created successfully." and the details page of the new request opens.

### C2. New Service [SCREENSHOT]
1. Back on the dashboard, in the **New Service** card click **Start**.
2. Fill in: Service Name, Description, Requestor, choose the asset (e.g. IMA; Asset Owner fills in),
   Service Type (Frontend or Backend), Repo Link (e.g. https://github.com/Deloitte-US-Tax/example),
   Target date, and tick at least one environment.
3. Click **Create request**.
4. Expected: created successfully; the details page shows the asset you chose.

### C3. Existing Asset / Service - all three request types [SCREENSHOT]
Repeat three times, once for each request type card:
1. In the **Existing Asset / Service** card click **Start**.
2. Choose the request type card: **Modify service**, then (next time) **Additional infrastructure**, then
   **New feature / change**.
3. Choose the Existing Asset Name (e.g. IMA), enter the Existing Service Name, Description, Requestor,
   Asset Owner, Target date, and tick at least one environment.
4. Click **Submit request**.
5. Expected: created successfully. All three appear on the dashboard with type "Existing asset / service".

### C4. Validation messages
1. **New Service** without choosing an asset -> "Select an asset for the new service."
2. **Existing Asset / Service** without choosing an asset -> "Select an existing asset."
3. Any form with a required field left empty -> "Complete all required fields."
4. Any form with no environment ticked -> "Select at least one required environment." (or "Select at least one environment.")
5. Expected: no request is created in these cases.

### C5. Requests are stored on the server
1. On the dashboard press **F5** (refresh).
2. Expected: all requests from C1-C3 are still listed (they come from the API, not the browser).

### C6. Search and filters
1. Type part of a request name in the search box.
2. Click the filters **All**, **In progress**, **Waiting / Blocked**, **Completed**.
3. Expected: the list and the counts change accordingly; **Clear filters** shows everything again.

---

## D. Roles

### D1. Manager sees all requests [SCREENSHOT]
1. Log out, sign in as `demo.manager`.
2. Expected: the dashboard lists all requests, including the ones demo.requester created.

### D2. Manager cannot create requests
1. As `demo.manager`, look at the top of the dashboard.
2. Expected: the three cards New Asset / New Service / Existing Asset / Service are not shown (only a
   Requester can start a request).

### D3. Manager changes the status [SCREENSHOT]
1. As `demo.manager`, open one of the requests.
2. In **Update request status**, choose **In progress** in Request status and click **Save status**.
3. Expected: the status changes; back on the dashboard the **In progress** count goes up.

### D4. Requester sees the new status, and only their own requests
1. Log out, sign in as `demo.requester`.
2. Expected: the request shows status "In progress". The requester has no **Update request status** section.

### D5. Administrator
1. Log out, sign in as `demo.admin`.
2. Expected: a **User management** link in the header. The dashboard shows no requests and no create
   cards (an administrator only manages users).

---

## E. User management (signed in as demo.admin, http://localhost:4200/admin/users)

### E1. Create a user [SCREENSHOT]
1. In **Create user** fill Username `test.requester`, Display name `Test Requester`, a Password, and tick
   the role **Requester**. Click **Create user**.
2. Expected: "User test.requester created." and the user appears in the **Users** list.

### E2. Sign in as the new user
1. Log out, sign in as `test.requester` with the password you set.
2. Expected: same view as demo.requester: the three create cards are shown, and only this user's own
   requests are listed (none yet).

### E3. Change roles
1. As `demo.admin`, in **Users** add the role **Onboarding Manager** to `test.requester` and save.
2. Sign in as `test.requester` again.
3. Expected: now sees all requests and the **Update request status** section.

### E4. Last administrator is protected
1. As `demo.admin`, try to remove the **Administrator** role from `demo.admin` (the only administrator).
2. Expected: blocked with "Cannot remove the Administrator role from the last active administrator."

---

## F. API checks in Swagger (optional), http://localhost:5000/swagger

### F1. Requests need a token
1. Open **GET /api/onboarding-requests**, click **Try it out**, then **Execute** (without authorizing).
2. Expected: response code **401**.

### F2. Sign in and filter by asset [SCREENSHOT]
1. Open **POST /api/auth/login**, **Try it out**, body:
   `{ "username": "demo.requester", "password": "<password>" }`, **Execute**. Copy the `accessToken` value.
2. Click **Authorize** (top right), paste the token, **Authorize**, **Close**.
3. Open **GET /api/onboarding-requests**, enter `IMA` in assetName, **Execute**.
4. Expected: response code **200** with only the IMA requests (the New Service and Existing ones from C2/C3).

---

## After testing

- Keep the screenshots for the ticket comment.
- Stop the demo (data kept):
  ```powershell
  .\start-onboarding-demo-docker.ps1 -WorkDir "C:\Cloned Repositories" -Stop
  ```
- Start again later without rebuilding: add `-NoBuild` instead of `-Stop`.
- Start over with an empty database: `-Reset` (asks for confirmation; the logins are kept).

If a step does not behave as described, take a screenshot of it and note the step number.
