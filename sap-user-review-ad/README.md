# SAP user review – line manager lookup in Active Directory

ABAP objects that find the line manager of each SAP user in Active Directory
(on-premises AD over LDAP, through SAP's LDAP connector). Run it after the CUA
step has collected and enriched the users.

## How it works

1. Every SAP user is matched to an AD account by one key (configurable):
   * `SAM`: SAP user ID = `sAMAccountName` (default)
   * `MAIL`: default e-mail in the user master (USR21/ADR6) = `mail`
   * `UPN`: default e-mail in the user master = `userPrincipalName`
   * or an explicit `AD_KEY` per user, which overrides the mapping
2. The accounts are read in batches of 50 (one LDAP OR-filter per batch).
3. The `manager` attribute (a DN) of each account is collected, and those DNs are
   read in batches as well.
4. The manager's SAP user is looked up (by `sAMAccountName` = user ID, then by
   e-mail address).
5. There is one result row per input user, in input order, with a status:

| Status | Meaning |
|---|---|
| `S` | Manager found (`MESSAGE` says if the manager's AD account is disabled) |
| `N` | No AD account for the SAP user (or no e-mail address to match on) |
| `A` | Several AD accounts match (for example, admin accounts sharing an e-mail address) |
| `M` | AD account has no `manager` maintained |
| `U` | Manager DN could not be read below the search base |

`AD_DISABLED`/`MGR_DISABLED` come from `userAccountControl` (ACCOUNTDISABLE).
They point out leavers, and reviews still assigned to a manager who has left.

## Objects

| Object | Type | Purpose |
|---|---|---|
| `ZCX_UR_AD_ERROR` | Exception class | LDAP/configuration errors |
| `ZIF_UR_LDAP_CLIENT` | Interface | Thin LDAP abstraction (bind/search/unbind) |
| `ZCL_UR_LDAP_CLIENT` | Class | Implementation using `LDAP_SYSTEMBIND` / `LDAP_READ` / `LDAP_UNBIND` |
| `ZIF_UR_MANAGER_LOOKUP` | Interface | Public API and result types |
| `ZCL_UR_AD_MANAGER_LOOKUP` | Class | Matching, batching, manager resolution (+ ABAP Unit tests) |
| `Z_UR_GET_AD_MANAGERS` | Function module (group `ZUR_AD`), RFC-enabled | Entry point for remote callers |
| `ZUR_AD_MANAGER_REPORT` | Report | Standalone ALV output, for testing and ad-hoc use |

The file names follow abapGit conventions (`*.clas.abap`, `*.clas.testclasses.abap`, ...).
Create the objects in this order: exception class, interfaces, `ZCL_UR_LDAP_CLIENT`,
`ZCL_UR_AD_MANAGER_LOOKUP`, then the DDIC objects, the function module and the report.
You need ABAP 7.40 SP08 or later (inline declarations, constructor expressions, new Open SQL).

### DDIC objects for the function module

RFC needs dictionary types, so create these in SE11:

**Structure `ZUR_S_AD_USER`**, table type `ZUR_T_AD_USER` (standard table)

| Field | Type |
|---|---|
| `BNAME` | `XUBNAME` |
| `EMAIL` | `AD_SMTPADR` |
| `AD_KEY` | `CHAR255` |

**Structure `ZUR_S_AD_MANAGER`**, table type `ZUR_T_AD_MANAGER` (standard table)

| Field | Type | Field | Type |
|---|---|---|---|
| `BNAME` | `XUBNAME` | `MGR_DN` | `CHAR255` |
| `LOOKUP_KEY` | `CHAR255` | `MGR_SAM` | `CHAR40` |
| `STATUS` | `CHAR1` | `MGR_UPN` | `AD_SMTPADR` |
| `MESSAGE` | `CHAR255` | `MGR_MAIL` | `AD_SMTPADR` |
| `AD_DN` | `CHAR255` | `MGR_NAME` | `CHAR80` |
| `AD_SAM` | `CHAR40` | `MGR_DISABLED` | `XFELD` |
| `AD_UPN` | `AD_SMTPADR` | `MGR_BNAME` | `XUBNAME` |
| `AD_MAIL` | `AD_SMTPADR` | | |
| `AD_NAME` | `CHAR80` | | |
| `AD_DISABLED` | `XFELD` | | |

The field names must match `ZIF_UR_MANAGER_LOOKUP=>TY_RESULT`, because the
function module maps them with `CORRESPONDING`.

## System setup

1. **LDAP connector**: transaction `LDAP`, then *Connector*. Make sure a connector runs
   on the application server(s).
2. **LDAP server**: in transaction `LDAP`, under *Server*, create a server ID (for example `CORP_AD`):
   * Host: a domain controller, or better the **Global Catalog** (port 3268, or 3269 with
     SSL) if users and managers are spread over several domains. `manager`,
     `mail`, `userPrincipalName`, `sAMAccountName`, `displayName` and
     `userAccountControl` are all in the GC partial attribute set.
   * Product: Microsoft Active Directory
   * **System user**: a read-only AD service account. `LDAP_SYSTEMBIND`
     uses it, so no credentials live in the code. Use LDAPS/SSL if you can.
3. **Test the bind** in transaction `LDAP` (*Log on*) before running the report.
4. **Authorizations**: the executing (or RFC) user needs the LDAP connector
   authorizations (check `SU53` after a first run) and `S_USER_GRP` with
   `ACTVT 03`. The function module checks the latter, because manager
   relationships are personal data.
5. **Search base**: for example `DC=corp,DC=example,DC=com`. Managers are read with the same
   base, so it must cover all OUs where managers live (status `U` otherwise).

## Usage in the review tool

```abap
DATA(lt_users) = VALUE zif_ur_manager_lookup=>tt_user(
  FOR ls_cua IN lt_cua_users ( bname = ls_cua-bname email = ls_cua-email ) ).

TRY.
    DATA(lt_managers) = zcl_ur_ad_manager_lookup=>create(
        iv_server_id = 'CORP_AD'
        iv_base_dn   = `DC=corp,DC=example,DC=com`
        iv_key_type  = zif_ur_manager_lookup=>gc_key_type-sam
      )->get_managers( lt_users ).
  CATCH zcx_ur_ad_error INTO DATA(lx_error).
    " connection/bind/search failure – nothing was resolved
ENDTRY.
```

If the review tool runs in another system, call `Z_UR_GET_AD_MANAGERS` via RFC
in the system where the LDAP connector is configured.

## Things to verify on your release

* **`LDAP_READ` interface**: the parameter names and the line types of
  `LDAPASTAB`/`LDAPETAB` differ slightly between NetWeaver releases. Compare
  `ZCL_UR_LDAP_CLIENT=>SEARCH` with SE37. It reads the result generically, and it is
  the only place that calls the `LDAP_*` function modules. If `base`/`filter`
  are typed as fixed-length CHAR on your release, use `base_string`/`filter_string`.
* **Size limit**: AD returns at most 1000 entries per query (`MaxPageSize`).
  Batches of 50 keys stay far below that.
* **Entra ID (Azure AD) only**: if some users exist only in Entra ID, add a second
  implementation of `ZIF_UR_MANAGER_LOOKUP` that calls Microsoft Graph
  (`GET /users/{upn}?$expand=manager`). Callers don't need to change.
