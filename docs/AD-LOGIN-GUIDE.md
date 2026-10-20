# SecureDesk me Active Directory (AD) login: A se Z tak guide

Ye guide Hinglish me hai, taaki aap ise khud samajh kar dusron ko explain kar sako.
Pehle ke hisse me "ye sab kya hota hai" hai, phir real AD me lagane ke steps, phir roz ke kaam, phir problem aaye to kya karein.

Status: feature banaya aur nakli LDAP server (GLAuth) par test kiya hai. Asli company AD par abhi test nahi hua.

---

## Hissa 1: Pehle ye shabd samajh lo

| Shabd | Matlab (seedhi bhasha me) |
|---|---|
| **Active Directory (AD)** | Company ki "user list" jo Windows server par rehti hai. Har employee ka username aur password wahi hota hai. |
| **Domain Controller (DC)** | Wo server jahan AD chalta hai. Hum SecureDesk ko is se baat karna sikhate hain. Example: `dc01.company.local` |
| **LDAP / LDAPS** | AD se baat karne ki bhasha (protocol). **LDAPS** matlab same baat par secure (encrypted) tareeke se, port **636**. Hum hamesha LDAPS use karte hain, kyunki password network par jata hai. |
| **Base DN** | AD ke andar "kahan se dhoondhna hai" ka address. Domain `company.local` ka Base DN `DC=company,DC=local` hota hai. |
| **Service account** | Ek chhota, sirf-padhne-wala AD user (jaise `svc-securedesk`). SecureDesk isse login karke AD me "raju kaun hai, kis group me hai" dhoondhta hai. Ise admin power nahi deni. |
| **Group** | AD me logon ka samuh. Hum 2 groups banate hain: `SecureDesk-Admins` aur `SecureDesk-Techs`. |
| **2FA (authenticator code)** | Password ke baad phone ke app (Google/Microsoft Authenticator) ka 6 digit code. Password chori ho jaye tab bhi akela kaam nahi aata. |
| **`ad-config.env`** | Ek file jisme AD ki saari details hain (server, base DN, service account, password, groups). Sirf server par rehti hai. |
| **`ad-users.txt`** | Ek file jisme un logon ke username hain jo SecureDesk me aa sakte hain. Har line me ek username. |
| **`apply-ad.sh`** | Ek script jo upar ki dono files ko check karti hai, AD se connection test karti hai, aur sab sahi ho to AD login ON kar deti hai. |

### Login kaise chalta hai (ek line me)
`raju` apna AD username aur password likhta hai, SecureDesk AD se poochta hai "ye sahi hai?", AD haan bole, to SecureDesk phone ka 6 digit code maangta hai, code sahi ho to andar.

SecureDesk raju ka password kahin save nahi karta. Har baar AD se hi check hota hai.

### 3 suraksha parte (taaki dusron ko bata sako)
1. **List me hona zaroori:** AD me ho tab bhi, naam `ad-users.txt` me na ho to login nahi.
2. **Group zaroori (agar groups bhare hain):** `SecureDesk-Admins` ya `SecureDesk-Techs` me hona zaroori.
3. **2FA zaroori:** `AD_REQUIRE_2FA=true` default hai. Ise sirf server ka admin file se badal sakta hai, web se nahi.

---

## Hissa 2: Asli AD me lagane ke steps

Do log hote hain: **AD admin** (Windows server sambhalne wala) aur **SecureDesk admin** (aap). Jo step AD admin ka hai, wo uske naam likha hai.

### Step 1 (AD admin): Service account banao
**Kya aur kyun:** SecureDesk ko AD me user dhoondhne ke liye ek login chahiye. Alag account isliye ki password badle ya account hate to sirf wahi asar paye, kisi insaan ka account nahi.

DC par PowerShell (Administrator) me:
```powershell
New-ADUser -Name "svc-securedesk" -SamAccountName "svc-securedesk" `
  -UserPrincipalName "svc-securedesk@company.local" `
  -AccountPassword (Read-Host -AsSecureString "Password") `
  -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true
```
Is account ko **koi admin group me mat daalo**. Normal "Domain Users" kaafi hai, wo AD ki list padh sakta hai.
`PasswordNeverExpires` isliye ki password expire hone par achanak sabka login band ho jata hai.

### Step 2 (AD admin): 2 group banao aur log daalo
**Kya aur kyun:** group se SecureDesk jaanta hai ki kaun admin hai aur kaun technician.
```powershell
New-ADGroup -Name "SecureDesk-Admins" -GroupScope Global -GroupCategory Security
New-ADGroup -Name "SecureDesk-Techs"  -GroupScope Global -GroupCategory Security
Add-ADGroupMember -Identity "SecureDesk-Admins" -Members "amit"
Add-ADGroupMember -Identity "SecureDesk-Techs"  -Members "raju","priya"
```
Dhyan: log **seedhe** group ke member hon. Group ke andar group (nested) abhi support nahi hai.

### Step 3 (AD admin): Ye details nikaalo
```powershell
$env:USERDNSDOMAIN                      # domain naam, jaise company.local
(Get-ADDomain).DistinguishedName        # Base DN, jaise DC=company,DC=local
$env:LOGONSERVER                        # DC ka naam, jaise \\DC01
```
DC ka poora naam (FQDN) likho, jaise `dc01.company.local`. **IP address mat do**, kyunki secure connection me certificate ka naam server ke naam se milna chahiye. IP dene par certificate "naam match nahi" bol kar refuse ho jata hai.

### Step 4 (AD admin + aap): LDAPS chalu hai ya nahi dekho
**Kya aur kyun:** secure connection ke liye DC ke paas certificate chahiye. Agar company me Certificate Authority (AD CS) hai to DC ko ye mil chuka hota hai.

SecureDesk wale server (VM) se test:
```bash
timeout 6 bash -c 'echo > /dev/tcp/dc01.company.local/636' && echo OPEN || echo CLOSED
```
`CLOSED` aaye to firewall par SecureDesk server se DC ke port **636** ko allow karwao. Server ko `dc01.company.local` naam resolve bhi karna chahiye (DNS).

Agar certificate company ke apne CA ka hai, to us **CA ka root certificate** (Base-64 `.cer`) AD admin se lo, aur file ko `ad/ca.crt` naam do. Ye SecureDesk ko batata hai "is certificate par bharosa karo".

### Step 5 (aap): Files bharo
SecureDesk ke folder me (jahan `docker-compose.yml` hai):
```bash
cd /appdata/securedesk
cp ad/ad-config.env.example ad/ad-config.env
cp ad/ad-users.txt.example  ad/ad-users.txt
nano ad/ad-config.env
nano ad/ad-users.txt
```
`ad-config.env` me ye bharo:
```
AD_SERVER=dc01.company.local
AD_PORT=636
AD_USE_LDAPS=true
AD_DOMAIN=company.local
AD_BASE_DN=DC=company,DC=local
AD_SERVICE_ACCOUNT=svc-securedesk@company.local
AD_SERVICE_PASSWORD=<service account ka password>
AD_ADMINS_GROUP=SecureDesk-Admins
AD_TECHS_GROUP=SecureDesk-Techs
AD_CA_CERT_FILE=/ad/ca.crt        # sirf agar company ka apna CA hai
AD_REQUIRE_2FA=true               # aisa hi rehne do
```
`AD_ENABLED` ko `false` hi rehne do, `apply-ad.sh` use khud `true` karegi.
`ad-users.txt` me har line me ek AD logon-name (sAMAccountName), bina domain ke:
```
raju
amit
priya
```
Ye files Git me kabhi nahi jaati aur image ke andar bhi nahi. Password sirf is server par rehta hai.

### Step 6 (aap): `apply-ad.sh` chalao
```bash
./apply-ad.sh
```
Ye script kya karti hai (har `OK` ka matlab):
| Output | Matlab |
|---|---|
| `OK values filled in, N user(s)` | Zaroori cheezein bhari hain aur users list khali nahi. |
| `OK 2FA is required for AD users` | 2FA zaroori hai. |
| `OK file permissions set` | Config file sirf owner padh sake (permission 600), kyunki usme password hai. |
| `OK/NOTE ... is reachable` | Server tak connection. NOTE aaye to dar mat, asli test agla step hai. |
| `OK: Service account can sign in and the base DN is readable.` | **Sabse zaroori:** service account ka password sahi hai aur Base DN sahi hai. Ye test SecureDesk ke container ke andar se hota hai, jahan se asli login chalega. |
| `OK AD_ENABLED=true` aur `SecureDesk is back up` | AD login ON hua aur server restart hokar wapas aa gaya. |

Koi bhi step fail hua to script rukti hai, `FAILED: ...` likhti hai, aur AD ON nahi karti. Purana (local) login chalta rehta hai. Gadbad hone par kabhi login band nahi hota.

Ek user ka password bhi test karna ho:
```bash
./apply-ad.sh --test-login raju
```
Ye password silent poochti hai (screen par nahi dikhta) aur kahin save nahi karti.

### Step 7: Pehla asli login (har user ka)
1. User SecureDesk kholta hai, username `raju` aur AD password likhta hai.
2. Seedha **authenticator setup page** khulta hai. Console abhi band hai.
3. Phone me Google ya Microsoft Authenticator kholo, QR scan karo (ya "Shared key" haath se daalo).
4. App ka 6 digit code daal kar confirm karo.
5. **10 recovery codes** dikhenge. Inhe sambhal kar rakhna. Phone kho jaye to inhi se andar ja sakte hain, har code sirf ek baar.
6. Ab console khulta hai.

Uske baad har login: username + password, phir 6 digit code.
Pehle login par SecureDesk me user **apne aap ban jata hai** (naam `raju@company.local`), AD group ke hisaab se role milta hai.

---

## Hissa 3: Roz ke kaam

| Kaam | Kaise |
|---|---|
| **Naya user jodna** | AD me use `SecureDesk-Techs` group me daalo **aur** `ad/ad-users.txt` me ek line jodo. Restart nahi chahiye. |
| **User hatana** | `ad-users.txt` se line mita do (turant asar) aur/ya AD me account disable karo. Agle login par refuse. |
| **Kisi ko admin banana** | AD me use `SecureDesk-Admins` me daalo. Agle login par Organization Admin ban jata hai. |
| **User ko sirf kuch device dikhana** | Ye AD me ya `ad-users.txt` me define nahi hota. Ye SecureDesk ke **Device Groups** se hota hai (neeche "Device access ka niyam" dekho). |
| **User ka password badalna / reset karna** | **Sirf AD me.** SecureDesk password save nahi karta, har login par AD se check karta hai. AD me reset karte hi naya password turant SecureDesk me chalta hai, purana band. SecureDesk ke "Forgot password" aur "Password" pages AD users ke liye band hain (wo sirf local accounts ke liye hain). |
| **AD login band karna** | `ad/ad-config.env` me `AD_ENABLED=false`, phir `docker compose restart securedesk`. Local admin ka login hamesha chalta hai. |
| **Service account ka password badla** | `ad-config.env` me naya password daalo, phir `./apply-ad.sh`. |
| **2FA band karna (sirf server admin, mat karo jab tak zaroori na ho)** | `AD_REQUIRE_2FA=false` aur `./apply-ad.sh --allow-no-2fa` (YES likhna padega). Admins ko laal warning dikhti rahegi. |

### Device access ka niyam (kaun sa user kaun si VM dekhta hai)
Ye data SecureDesk ke **apne database** me rehta hai (`securedesk-data` volume), AD me nahi. Us volume ka backup rakhna.

Niyam (code se verify kiya hai): ek **admin** ko sab device dikhte hain. Ek **normal technician** ko wo device dikhta hai agar:
- device **kisi group me nahi** hai, **ya**
- device ke group me **koi user nahi** hai, **ya**
- technician **us group ka member** hai.

Isliye "sirf VM 82" dene ke steps:
1. Raju ek baar login kare (pehle login par hi SecureDesk me uska user banta hai).
2. Organization me Device Group banao, jaise `Raju-VMs`. VM 82 ko usme daalo.
3. Group me user jodte waqt **poora naam** likho: `raju@company.local` (sirf `raju` nahi). Naam Organization ke users ki list me dikhta hai.
4. **Baaki sab VM ko bhi group me daalo, aur har us group me kam se kam ek user (jaise koi admin) rakho, raju nahi.** Warna jo VM kisi group me nahi hai, wo raju ko bhi dikhegi.
5. Raju ko Organization Admin mat banao.

### Abhi jo cheez nahi bani (sach bata raha hu)
- **Phone kho jaye to admin se 2FA reset:** abhi ye button nahi hai. Abhi ka tareeka: user recovery code se login kare. Recovery code bhi na ho to server admin ko database me us user ka 2FA band karna padega. Ye button banana baaki hai.
- AD group ke andar group (nested groups).
- Microsoft/Google "Sign in with" buttons.

---

## Hissa 4: Problem aaye to

| Screen par message | Asli wajah (server log me dikhti hai) | Kya karein |
|---|---|---|
| "Invalid login attempt." | Galat password, ya naam `ad-users.txt` me nahi, ya kisi group me nahi, ya user nahi mila. | Log dekho (neeche). |
| "The company directory is not reachable right now..." | DC tak connection nahi, ya certificate, ya service account ka password galat. | `./apply-ad.sh` chalao, wo wajah likhegi. Firewall port 636, DNS, certificate dekho. |
| "Too many wrong attempts. Please wait a few minutes..." | 5 galat password ke baad 5 minute ka lock. | 5 minute ruko. (Server restart se turant khulta hai.) |
| Login ke baad authenticator page par hi atka | 2FA abhi set nahi hua. | Setup poora karo. Wahi ek page khula rehta hai. |
| Code "invalid" | Phone ka time galat. | Phone ka time automatic karo. |

**Log dekhne ka command:**
```bash
docker compose logs --tail 200 securedesk | grep -iE "AD login|Active Directory"
```
Yahan har refuse ka asli kaaran likha hota hai (jaise `not in ad-users.txt`, `wrong password`, `not in the configured AD group`). Screen par jaan-boojh kar sirf "Invalid login attempt" dikhta hai, taaki koi bahar se andaza na laga sake ki kaun sa user exist karta hai.

---

## Hissa 5: Khud try karne ke liye test environment

Asli AD ke bina samajhne ke liye ek nakli LDAP server (GLAuth, Docker image `glauth/glauth`) chala sakte ho. Ye **sirf test ke liye** hai, production me kabhi nahi.

- Ek alag test folder me ek `docker-compose.yml` banao jisme SecureDesk aur `glauth/glauth` dono hon, aur `./ad` folder SecureDesk me `/ad` par read-only mount ho.
- GLAuth ki config me kuch nakli users (jaise `raju`, `amit`, `priya`, `mallory`) aur ek service account banao, saath me 2 groups (techs aur admins) aur ek aisa group jisme koi test user na ho.
- `ad/ad-config.env` me test ke liye ye alag settings lagti hain (GLAuth AD jaisa nahi hai):
  `AD_USE_LDAPS=false`, `AD_ALLOW_INSECURE=true`, `AD_USER_ATTRIBUTE=cn`, `AD_USER_FILTER=(objectClass=*)`, `AD_SERVER=<glauth service ka naam>`, `AD_PORT=3893`.
- Phir wahi `./apply-ad.sh`, aur browser me SecureDesk kholo.

Kya dekhna hai: `mallory` kisi group me nahi hai (refuse hona chahiye), `priya` ko `ad-users.txt` me jod kar dekh sakte ho, `amit` admins group me hai. Kaam khatam hone par test stack aur uska volume `docker compose down -v` se hata do.

---

## Hissa 6: Dusre ko explain karne ke liye 30 second ka saar
"SecureDesk ab company ke AD se login kar sakta hai. AD me do group banti hain, ek service account. Ek file me AD ki details, ek me allowed logon ki list. Ek script sab test karke chalu karti hai, galat hua to purana login chalta rehta hai. Har AD user ke liye phone ka 6 digit code zaroori hai, aur ye setting sirf server ka admin file se badal sakta hai."

## Asli AD ke liye kya chahiye
DC ka poora naam, Base DN, service account (naam), do group ke naam, users ki list, aur (agar company ka apna CA hai) CA ka root certificate. **Service account ka password kisi ko bhejna nahi** (chat ya email me), wo sirf `ad/ad-config.env` me likhna.
