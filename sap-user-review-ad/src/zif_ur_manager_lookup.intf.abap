"! Determines the line manager of SAP users from a directory
INTERFACE zif_ur_manager_lookup
  PUBLIC.

  TYPES ty_key_type TYPE c LENGTH 4.
  TYPES ty_status   TYPE c LENGTH 1.

  CONSTANTS:
    "! How a SAP user is matched to its directory account
    BEGIN OF gc_key_type,
      sam  TYPE ty_key_type VALUE 'SAM',   " SAP user ID = sAMAccountName
      mail TYPE ty_key_type VALUE 'MAIL',  " SAP e-mail  = mail
      upn  TYPE ty_key_type VALUE 'UPN',   " SAP e-mail  = userPrincipalName
    END OF gc_key_type,
    BEGIN OF gc_status,
      ok                 TYPE ty_status VALUE 'S', " manager found
      not_found          TYPE ty_status VALUE 'N', " no AD account for the SAP user
      ambiguous          TYPE ty_status VALUE 'A', " several AD accounts match
      no_manager         TYPE ty_status VALUE 'M', " AD account has no manager maintained
      manager_unresolved TYPE ty_status VALUE 'U', " manager DN not readable below search base
    END OF gc_status.

  TYPES:
    BEGIN OF ty_user,
      bname  TYPE xubname,
      "! Optional; read from the user master (USR21/ADR6) when empty and needed
      email  TYPE ad_smtpadr,
      "! Optional explicit lookup value; overrides the key type mapping
      ad_key TYPE string,
    END OF ty_user,
    tt_user TYPE STANDARD TABLE OF ty_user WITH EMPTY KEY,

    BEGIN OF ty_result,
      bname        TYPE xubname,
      lookup_key   TYPE string,
      status       TYPE ty_status,
      message      TYPE string,
      " the user's own AD account
      ad_dn        TYPE string,
      ad_sam       TYPE string,
      ad_upn       TYPE string,
      ad_mail      TYPE string,
      ad_name      TYPE string,
      ad_disabled  TYPE abap_bool,
      " the manager's AD account
      mgr_dn       TYPE string,
      mgr_sam      TYPE string,
      mgr_upn      TYPE string,
      mgr_mail     TYPE string,
      mgr_name     TYPE string,
      mgr_disabled TYPE abap_bool,
      "! The manager's SAP user, if one could be identified
      mgr_bname    TYPE xubname,
    END OF ty_result,
    tt_result TYPE STANDARD TABLE OF ty_result WITH EMPTY KEY.

  "! Returns one result per input user, in input order
  METHODS get_managers
    IMPORTING
      it_users          TYPE tt_user
    RETURNING
      VALUE(rt_results) TYPE tt_result
    RAISING
      zcx_ur_ad_error.

ENDINTERFACE.
