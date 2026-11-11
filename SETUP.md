# Bar Check: automatic release setup (one time)

## A. Accounts (same username everywhere)
1. CurseForge author account: authors.curseforge.com
2. Wago Addons account: addons.wago.io
3. GitHub account: github.com

## B. Create the projects
1. CurseForge: Start a project > World of Warcraft > Addons. Fill in the name, summary, logo,
   description and license (MIT). Copy the **Project ID** from the project page.
2. Wago: create a new addon project. Copy the **Wago project ID** from the developer dashboard.

## C. Do the first upload by hand
Upload BarCheck_v1.2.0.zip on CurseForge as **Beta** and wait for moderation approval.
While doing this, check whether **WoW: Forever** is listed as a game version. If it isn't,
ask in the CurseForge Authors Discord which version to use before turning on automation.

## D. Make the GitHub repo
1. New repository named `BarCheck` (public is fine; it's MIT).
2. Put the **contents** of your BarCheck addon folder at the top level of the repo
   (BarCheck.toc, the .lua files, art folders, LICENSE.txt, README.txt).
3. Add the files from this kit: `.pkgmeta`, `.gitignore`, `CHANGELOG.md`, `SETUP.md`,
   and `.github/workflows/release.yml` (keep that folder path exactly).

## E. Add two lines to BarCheck.toc
```
## X-Curse-Project-ID: 000000
## X-Wago-ID: xxxxxxxx
```
(Swap in your real IDs. Change `## Version:` to `@project-version@` and the packager will
fill it in from the tag.)

## F. API tokens > GitHub secrets
1. CurseForge: account settings > API Tokens > generate one.
2. Wago: addons.wago.io/account/apikeys > generate one.
3. GitHub repo > Settings > Secrets and variables > Actions > New repository secret:
   - `CF_API_KEY` = the CurseForge token
   - `WAGO_API_TOKEN` = the Wago token
   (A missing secret just skips that site.)
4. GitHub repo > Settings > Actions > General > Workflow permissions > **Read and write**.

## G. Releasing an update
1. Update the code and add a new section at the top of CHANGELOG.md.
2. Make a tag and push it:
   - Test build: `v1.3.0-beta`  (a tag with "beta" uploads as Beta)
   - Real build: `v1.3.0`       (a plain tag uploads as Release)
3. Watch the Actions tab on GitHub. A green check means it uploaded.
   (GitHub Desktop: History > right-click the commit > Create Tag, then Push.)
