"! Determines the line manager of SAP users from Active Directory.
"!
"! 1. Maps every SAP user to its AD account (sAMAccountName, mail or UPN)
"! 2. Reads the accounts in batches (one LDAP OR-filter per batch)
"! 3. Reads the accounts referenced by their "manager" attribute (a DN)
"! 4. Tries to find the manager's own SAP user
"!
"! Usage:
"!   DATA(lo_lookup) = zcl_ur_ad_manager_lookup=>create(
"!                       iv_server_id = 'CORP_AD'
"!                       iv_base_dn   = `DC=corp,DC=example,DC=com` ).
"!   DATA(lt_result) = lo_lookup->get_managers( lt_users ).
CLASS zcl_ur_ad_manager_lookup DEFINITION
  PUBLIC
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_ur_manager_lookup.

    "! @parameter io_ldap       | LDAP access
    "! @parameter iv_base_dn    | Search base, e.g. DC=corp,DC=example,DC=com
    "! @parameter iv_key_type   | How a SAP user is matched to an AD account
    "! @parameter iv_batch_size | Accounts per LDAP query
    METHODS constructor
      IMPORTING
        io_ldap       TYPE REF TO zif_ur_ldap_client
        iv_base_dn    TYPE string
        iv_key_type   TYPE zif_ur_manager_lookup=>ty_key_type DEFAULT zif_ur_manager_lookup=>gc_key_type-sam
        iv_batch_size TYPE i DEFAULT 50.

    "! Lookup against an LDAP server maintained in transaction LDAP
    CLASS-METHODS create
      IMPORTING
        iv_server_id     TYPE ldapserver-serverid
        iv_base_dn       TYPE string
        iv_key_type      TYPE zif_ur_manager_lookup=>ty_key_type DEFAULT zif_ur_manager_lookup=>gc_key_type-sam
      RETURNING
        VALUE(ro_lookup) TYPE REF TO zif_ur_manager_lookup.

    "! Escapes a value for use in an LDAP search filter (RFC 4515)
    CLASS-METHODS escape_filter_value
      IMPORTING
        iv_value          TYPE string
      RETURNING
        VALUE(rv_escaped) TYPE string.

  PROTECTED SECTION.
    TYPES:
      BEGIN OF ty_ad_user,
        dn           TYPE string,
        sam          TYPE string,
        upn          TYPE string,
        mail         TYPE string,
        display_name TYPE string,
        manager_dn   TYPE string,
        disabled     TYPE abap_bool,
        bname        TYPE xubname,
      END OF ty_ad_user,
      "! AD accounts by lower-case match value; hits > 1 means ambiguous
      BEGIN OF ty_ad_index,
        key  TYPE string,
        hits TYPE i,
        user TYPE ty_ad_user,
      END OF ty_ad_index,
      tt_ad_index TYPE HASHED TABLE OF ty_ad_index WITH UNIQUE KEY key.

    DATA mv_key_type TYPE zif_ur_manager_lookup=>ty_key_type.

    "! Fills EMAIL from the user master (USR21/ADR6) where it is empty
    METHODS read_sap_emails
      CHANGING
        ct_users TYPE zif_ur_manager_lookup=>tt_user.

    "! Fills USER-BNAME with the matching SAP user of each AD account, if any
    METHODS map_to_sap_users
      CHANGING
        ct_index TYPE tt_ad_index.

  PRIVATE SECTION.
    CONSTANTS gc_person_filter TYPE string VALUE `(objectCategory=person)(objectClass=user)`.

    DATA mo_ldap       TYPE REF TO zif_ur_ldap_client.
    DATA mv_base_dn    TYPE string.
    DATA mv_batch_size TYPE i.

    METHODS key_attribute
      RETURNING
        VALUE(rv_attribute) TYPE string.

    METHODS search_accounts
      IMPORTING
        iv_attribute    TYPE string
        it_values       TYPE string_table
      RETURNING
        VALUE(rt_index) TYPE tt_ad_index
      RAISING
        zcx_ur_ad_error.

    CLASS-METHODS to_ad_user
      IMPORTING
        is_entry       TYPE zif_ur_ldap_client=>ty_entry
      RETURNING
        VALUE(rs_user) TYPE ty_ad_user.

    CLASS-METHODS first_value
      IMPORTING
        is_entry        TYPE zif_ur_ldap_client=>ty_entry
        iv_name         TYPE string
      RETURNING
        VALUE(rv_value) TYPE string.
ENDCLASS.


CLASS zcl_ur_ad_manager_lookup IMPLEMENTATION.

  METHOD constructor.
    mo_ldap       = io_ldap.
    mv_base_dn    = iv_base_dn.
    mv_key_type   = iv_key_type.
    mv_batch_size = COND #( WHEN iv_batch_size > 0 THEN iv_batch_size ELSE 50 ).
  ENDMETHOD.


  METHOD create.
    ro_lookup = NEW zcl_ur_ad_manager_lookup(
      io_ldap     = NEW zcl_ur_ldap_client( iv_server_id )
      iv_base_dn  = iv_base_dn
      iv_key_type = iv_key_type ).
  ENDMETHOD.


  METHOD zif_ur_manager_lookup~get_managers.
    DATA lt_keys    TYPE string_table.
    DATA lt_mgr_dns TYPE string_table.
    DATA lt_accounts TYPE tt_ad_index.
    DATA lt_managers TYPE tt_ad_index.

    DATA(lt_users) = it_users.
    IF mv_key_type <> zif_ur_manager_lookup=>gc_key_type-sam.
      read_sap_emails( CHANGING ct_users = lt_users ).
    ENDIF.

    " 1. AD lookup key per SAP user
    LOOP AT lt_users INTO DATA(ls_user).
      APPEND VALUE #( bname = ls_user-bname ) TO rt_results ASSIGNING FIELD-SYMBOL(<ls_result>).
      <ls_result>-lookup_key = to_lower( condense( COND string(
        WHEN ls_user-ad_key IS NOT INITIAL                        THEN ls_user-ad_key
        WHEN mv_key_type = zif_ur_manager_lookup=>gc_key_type-sam THEN ls_user-bname
        ELSE ls_user-email ) ) ).
      IF <ls_result>-lookup_key IS INITIAL.
        <ls_result>-status  = zif_ur_manager_lookup=>gc_status-not_found.
        <ls_result>-message = `No e-mail address in the SAP user master`.
      ELSE.
        APPEND <ls_result>-lookup_key TO lt_keys.
      ENDIF.
    ENDLOOP.
    SORT lt_keys.
    DELETE ADJACENT DUPLICATES FROM lt_keys.
    IF lt_keys IS INITIAL.
      RETURN.
    ENDIF.

    mo_ldap->bind( ).
    TRY.
        " 2. The users' own accounts
        lt_accounts = search_accounts( iv_attribute = key_attribute( ) it_values = lt_keys ).

        " 3. Their managers, by distinguished name
        LOOP AT lt_accounts INTO DATA(ls_account) WHERE hits = 1 AND user-manager_dn IS NOT INITIAL.
          APPEND to_lower( ls_account-user-manager_dn ) TO lt_mgr_dns.
        ENDLOOP.
        SORT lt_mgr_dns.
        DELETE ADJACENT DUPLICATES FROM lt_mgr_dns.
        IF lt_mgr_dns IS NOT INITIAL.
          lt_managers = search_accounts( iv_attribute = `distinguishedName` it_values = lt_mgr_dns ).
        ENDIF.
      CLEANUP.
        mo_ldap->unbind( ).
    ENDTRY.
    mo_ldap->unbind( ).

    " 4. Managers' SAP users
    map_to_sap_users( CHANGING ct_index = lt_managers ).

    LOOP AT rt_results ASSIGNING <ls_result> WHERE status IS INITIAL.
      READ TABLE lt_accounts INTO ls_account WITH TABLE KEY key = <ls_result>-lookup_key.
      IF sy-subrc <> 0.
        <ls_result>-status  = zif_ur_manager_lookup=>gc_status-not_found.
        <ls_result>-message = |No AD account with { key_attribute( ) } { <ls_result>-lookup_key }|.
        CONTINUE.
      ENDIF.
      IF ls_account-hits > 1.
        <ls_result>-status  = zif_ur_manager_lookup=>gc_status-ambiguous.
        <ls_result>-message = |{ ls_account-hits } AD accounts with { key_attribute( ) } { <ls_result>-lookup_key }|.
        CONTINUE.
      ENDIF.

      <ls_result>-ad_dn       = ls_account-user-dn.
      <ls_result>-ad_sam      = ls_account-user-sam.
      <ls_result>-ad_upn      = ls_account-user-upn.
      <ls_result>-ad_mail     = ls_account-user-mail.
      <ls_result>-ad_name     = ls_account-user-display_name.
      <ls_result>-ad_disabled = ls_account-user-disabled.
      <ls_result>-mgr_dn      = ls_account-user-manager_dn.

      IF ls_account-user-manager_dn IS INITIAL.
        <ls_result>-status  = zif_ur_manager_lookup=>gc_status-no_manager.
        <ls_result>-message = `No manager maintained in AD`.
        CONTINUE.
      ENDIF.

      DATA(lv_mgr_key) = to_lower( ls_account-user-manager_dn ).
      READ TABLE lt_managers INTO DATA(ls_manager) WITH TABLE KEY key = lv_mgr_key.
      IF sy-subrc <> 0.
        <ls_result>-status  = zif_ur_manager_lookup=>gc_status-manager_unresolved.
        <ls_result>-message = `Manager account not found below the search base`.
        CONTINUE.
      ENDIF.

      <ls_result>-mgr_sam      = ls_manager-user-sam.
      <ls_result>-mgr_upn      = ls_manager-user-upn.
      <ls_result>-mgr_mail     = ls_manager-user-mail.
      <ls_result>-mgr_name     = ls_manager-user-display_name.
      <ls_result>-mgr_disabled = ls_manager-user-disabled.
      <ls_result>-mgr_bname    = ls_manager-user-bname.
      <ls_result>-status       = zif_ur_manager_lookup=>gc_status-ok.
      IF ls_manager-user-disabled = abap_true.
        <ls_result>-message = `Manager's AD account is disabled`.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD search_accounts.
    DATA(lt_attributes) = VALUE string_table(
      ( `sAMAccountName` ) ( `userPrincipalName` ) ( `mail` )
      ( `displayName` ) ( `manager` ) ( `userAccountControl` ) ).
    DATA(lv_attribute_lc) = to_lower( iv_attribute ).
    DATA(lv_count) = lines( it_values ).
    DATA(lv_from) = 1.

    WHILE lv_from <= lv_count.
      DATA(lv_to) = lv_from + mv_batch_size - 1.
      DATA(lv_or) = ``.
      LOOP AT it_values INTO DATA(lv_value) FROM lv_from TO lv_to.
        lv_or = |{ lv_or }({ iv_attribute }={ escape_filter_value( lv_value ) })|.
      ENDLOOP.
      lv_from = lv_to + 1.

      DATA(lt_entries) = mo_ldap->search(
        iv_base_dn    = mv_base_dn
        iv_filter     = |(&{ gc_person_filter }(\|{ lv_or }))|
        it_attributes = lt_attributes ).

      LOOP AT lt_entries INTO DATA(ls_entry).
        DATA(ls_user) = to_ad_user( ls_entry ).
        DATA(lv_key) = to_lower( COND string(
          WHEN lv_attribute_lc = `distinguishedname` THEN ls_user-dn
          ELSE first_value( is_entry = ls_entry iv_name = lv_attribute_lc ) ) ).
        IF lv_key IS INITIAL.
          CONTINUE.
        ENDIF.
        ASSIGN rt_index[ key = lv_key ] TO FIELD-SYMBOL(<ls_hit>).
        IF sy-subrc = 0.
          <ls_hit>-hits = <ls_hit>-hits + 1.
        ELSE.
          INSERT VALUE #( key = lv_key hits = 1 user = ls_user ) INTO TABLE rt_index.
        ENDIF.
      ENDLOOP.
    ENDWHILE.
  ENDMETHOD.


  METHOD to_ad_user.
    rs_user = VALUE #(
      dn           = is_entry-dn
      sam          = first_value( is_entry = is_entry iv_name = `samaccountname` )
      upn          = first_value( is_entry = is_entry iv_name = `userprincipalname` )
      mail         = first_value( is_entry = is_entry iv_name = `mail` )
      display_name = first_value( is_entry = is_entry iv_name = `displayname` )
      manager_dn   = first_value( is_entry = is_entry iv_name = `manager` ) ).

    " userAccountControl bit 0x2 = ACCOUNTDISABLE
    DATA(lv_uac) = condense( first_value( is_entry = is_entry iv_name = `useraccountcontrol` ) ).
    IF lv_uac IS NOT INITIAL AND lv_uac CO '0123456789'.
      rs_user-disabled = xsdbool( ( CONV i( lv_uac ) DIV 2 ) MOD 2 = 1 ).
    ENDIF.
  ENDMETHOD.


  METHOD first_value.
    READ TABLE is_entry-attributes INTO DATA(ls_attribute) WITH TABLE KEY name = iv_name.
    IF sy-subrc = 0.
      READ TABLE ls_attribute-values INTO rv_value INDEX 1.
    ENDIF.
  ENDMETHOD.


  METHOD key_attribute.
    rv_attribute = SWITCH #( mv_key_type
      WHEN zif_ur_manager_lookup=>gc_key_type-mail THEN `mail`
      WHEN zif_ur_manager_lookup=>gc_key_type-upn  THEN `userPrincipalName`
      ELSE `sAMAccountName` ).
  ENDMETHOD.


  METHOD escape_filter_value.
    rv_escaped = iv_value.
    " Backslash first, otherwise the escapes themselves would be escaped
    REPLACE ALL OCCURRENCES OF `\` IN rv_escaped WITH `\5c`.
    REPLACE ALL OCCURRENCES OF `*` IN rv_escaped WITH `\2a`.
    REPLACE ALL OCCURRENCES OF `(` IN rv_escaped WITH `\28`.
    REPLACE ALL OCCURRENCES OF `)` IN rv_escaped WITH `\29`.
  ENDMETHOD.


  METHOD read_sap_emails.
    DATA lt_missing TYPE STANDARD TABLE OF xubname WITH EMPTY KEY.

    lt_missing = VALUE #( FOR ls_user IN ct_users
                          WHERE ( email IS INITIAL AND ad_key IS INITIAL ) ( ls_user-bname ) ).
    IF lt_missing IS INITIAL.
      RETURN.
    ENDIF.

    SELECT u~bname, a~smtp_addr
      FROM usr21 AS u
      INNER JOIN adr6 AS a ON  a~addrnumber = u~addrnumber
                           AND a~persnumber = u~persnumber
      FOR ALL ENTRIES IN @lt_missing
      WHERE u~bname      = @lt_missing-table_line
        AND a~flgdefault = @abap_true
      INTO TABLE @DATA(lt_mail).
    SORT lt_mail BY bname.

    LOOP AT ct_users ASSIGNING FIELD-SYMBOL(<ls_user>) WHERE email IS INITIAL AND ad_key IS INITIAL.
      READ TABLE lt_mail INTO DATA(ls_mail) WITH KEY bname = <ls_user>-bname BINARY SEARCH.
      IF sy-subrc = 0.
        <ls_user>-email = ls_mail-smtp_addr.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD map_to_sap_users.
    TYPES:
      BEGIN OF ty_mail_user,
        mail  TYPE string,
        bname TYPE xubname,
      END OF ty_mail_user.
    DATA lt_bnames     TYPE STANDARD TABLE OF xubname WITH EMPTY KEY.
    DATA lt_srch       TYPE STANDARD TABLE OF adr6-smtp_srch WITH EMPTY KEY.
    DATA lt_mail_users TYPE HASHED TABLE OF ty_mail_user WITH UNIQUE KEY mail.

    IF ct_index IS INITIAL.
      RETURN.
    ENDIF.

    " a) sAMAccountName = SAP user ID (only where the user IDs are aligned)
    IF mv_key_type = zif_ur_manager_lookup=>gc_key_type-sam.
      lt_bnames = VALUE #( FOR ls_index IN ct_index
                           WHERE ( user-sam IS NOT INITIAL )
                           ( CONV xubname( to_upper( ls_index-user-sam ) ) ) ).
      IF lt_bnames IS NOT INITIAL.
        SELECT bname FROM usr02
          FOR ALL ENTRIES IN @lt_bnames
          WHERE bname = @lt_bnames-table_line
          INTO TABLE @DATA(lt_usr02).
        SORT lt_usr02 BY bname.
        LOOP AT ct_index ASSIGNING FIELD-SYMBOL(<ls_manager>) WHERE user-sam IS NOT INITIAL.
          " sAMAccountName may be up to 20 characters, SAP user IDs only 12
          IF strlen( <ls_manager>-user-sam ) > 12.
            CONTINUE.
          ENDIF.
          DATA(lv_bname) = CONV xubname( to_upper( <ls_manager>-user-sam ) ).
          READ TABLE lt_usr02 TRANSPORTING NO FIELDS WITH KEY bname = lv_bname BINARY SEARCH.
          IF sy-subrc = 0.
            <ls_manager>-user-bname = lv_bname.
          ENDIF.
        ENDLOOP.
      ENDIF.
    ENDIF.

    " b) AD mail = default e-mail address in the user master
    lt_srch = VALUE #( FOR ls_index IN ct_index
                       WHERE ( user-bname IS INITIAL AND user-mail IS NOT INITIAL )
                       ( CONV #( to_upper( ls_index-user-mail ) ) ) ).  " SMTP_SRCH = first 20 chars, upper case
    IF lt_srch IS INITIAL.
      RETURN.
    ENDIF.
    SORT lt_srch.
    DELETE ADJACENT DUPLICATES FROM lt_srch.

    SELECT u~bname, a~smtp_addr
      FROM adr6 AS a
      INNER JOIN usr21 AS u ON  u~addrnumber = a~addrnumber
                            AND u~persnumber = a~persnumber
      FOR ALL ENTRIES IN @lt_srch
      WHERE a~smtp_srch = @lt_srch-table_line
      INTO TABLE @DATA(lt_hits).
    SORT lt_hits BY bname.
    LOOP AT lt_hits INTO DATA(ls_hit).
      " First SAP user wins if several share an address
      INSERT VALUE #( mail = to_upper( ls_hit-smtp_addr ) bname = ls_hit-bname ) INTO TABLE lt_mail_users.
    ENDLOOP.

    LOOP AT ct_index ASSIGNING <ls_manager> WHERE user-bname IS INITIAL AND user-mail IS NOT INITIAL.
      DATA(lv_mail) = to_upper( <ls_manager>-user-mail ).
      READ TABLE lt_mail_users INTO DATA(ls_mail_user) WITH TABLE KEY mail = lv_mail.
      IF sy-subrc = 0.
        <ls_manager>-user-bname = ls_mail_user-bname.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.
