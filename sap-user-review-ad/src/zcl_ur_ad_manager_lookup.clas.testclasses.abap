*"* Local test classes of ZCL_UR_AD_MANAGER_LOOKUP

"! In-memory directory: an entry matches if the filter contains (attribute=value)
"! for its sAMAccountName, mail or DN
CLASS ltd_ldap DEFINITION FOR TESTING.
  PUBLIC SECTION.
    INTERFACES zif_ur_ldap_client.
    DATA mt_directory TYPE zif_ur_ldap_client=>tt_entries.
    DATA mv_searches  TYPE i.
    DATA mv_bound     TYPE abap_bool.
    METHODS add
      IMPORTING
        iv_dn      TYPE string
        iv_sam     TYPE string
        iv_mail    TYPE string OPTIONAL
        iv_manager TYPE string OPTIONAL
        iv_uac     TYPE string DEFAULT `512`.
ENDCLASS.

CLASS ltd_ldap IMPLEMENTATION.
  METHOD add.
    APPEND VALUE #(
      dn         = iv_dn
      attributes = VALUE #(
        ( name = `displayname`        values = VALUE #( ( |Name of { iv_sam }| ) ) )
        ( name = `mail`               values = VALUE #( ( iv_mail ) ) )
        ( name = `manager`            values = VALUE #( ( iv_manager ) ) )
        ( name = `samaccountname`     values = VALUE #( ( iv_sam ) ) )
        ( name = `useraccountcontrol` values = VALUE #( ( iv_uac ) ) ) ) ) TO mt_directory.
  ENDMETHOD.

  METHOD zif_ur_ldap_client~bind.
    mv_bound = abap_true.
  ENDMETHOD.

  METHOD zif_ur_ldap_client~unbind.
    mv_bound = abap_false.
  ENDMETHOD.

  METHOD zif_ur_ldap_client~search.
    mv_searches = mv_searches + 1.
    DATA(lv_filter) = to_lower( iv_filter ).
    LOOP AT mt_directory INTO DATA(ls_entry).
      DATA(lv_sam)  = to_lower( ls_entry-attributes[ name = `samaccountname` ]-values[ 1 ] ).
      DATA(lv_mail) = to_lower( ls_entry-attributes[ name = `mail` ]-values[ 1 ] ).
      IF lv_filter CS |(samaccountname={ lv_sam })|
          OR ( lv_mail IS NOT INITIAL AND lv_filter CS |(mail={ lv_mail })| )
          OR lv_filter CS |(distinguishedname={ zcl_ur_ad_manager_lookup=>escape_filter_value( to_lower( ls_entry-dn ) ) })|.
        APPEND ls_entry TO rt_entries.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.


"! Lookup without database access
CLASS ltd_lookup DEFINITION FOR TESTING INHERITING FROM zcl_ur_ad_manager_lookup.
  PROTECTED SECTION.
    METHODS read_sap_emails REDEFINITION.
    METHODS map_to_sap_users REDEFINITION.
ENDCLASS.

CLASS ltd_lookup IMPLEMENTATION.
  METHOD read_sap_emails.
    RETURN.
  ENDMETHOD.

  METHOD map_to_sap_users.
    LOOP AT ct_index ASSIGNING FIELD-SYMBOL(<ls_index>).
      <ls_index>-user-bname = to_upper( <ls_index>-user-sam ).
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.


CLASS ltc_lookup DEFINITION FOR TESTING RISK LEVEL HARMLESS DURATION SHORT.
  PRIVATE SECTION.
    CONSTANTS gc_base TYPE string VALUE `DC=corp,DC=example,DC=com`.
    DATA mo_ldap TYPE REF TO ltd_ldap.

    METHODS setup.
    METHODS lookup
      IMPORTING
        iv_key_type     TYPE zif_ur_manager_lookup=>ty_key_type DEFAULT zif_ur_manager_lookup=>gc_key_type-sam
        it_users        TYPE zif_ur_manager_lookup=>tt_user
      RETURNING
        VALUE(rt_result) TYPE zif_ur_manager_lookup=>tt_result
      RAISING
        zcx_ur_ad_error.

    METHODS resolves_manager       FOR TESTING RAISING zcx_ur_ad_error.
    METHODS unknown_user           FOR TESTING RAISING zcx_ur_ad_error.
    METHODS user_without_manager   FOR TESTING RAISING zcx_ur_ad_error.
    METHODS manager_outside_base   FOR TESTING RAISING zcx_ur_ad_error.
    METHODS ambiguous_mail         FOR TESTING RAISING zcx_ur_ad_error.
    METHODS disabled_manager       FOR TESTING RAISING zcx_ur_ad_error.
    METHODS keeps_input_order      FOR TESTING RAISING zcx_ur_ad_error.
    METHODS batches_queries        FOR TESTING RAISING zcx_ur_ad_error.
    METHODS escapes_filter_values  FOR TESTING.
ENDCLASS.

CLASS ltc_lookup IMPLEMENTATION.

  METHOD setup.
    mo_ldap = NEW #( ).
    mo_ldap->add( iv_dn   = `CN=Boss\, Anna,OU=Staff,DC=corp,DC=example,DC=com`
                  iv_sam  = `ABOSS`
                  iv_mail = `anna.boss@example.com` ).
    mo_ldap->add( iv_dn      = `CN=Doe\, John,OU=Staff,DC=corp,DC=example,DC=com`
                  iv_sam     = `JDOE`
                  iv_mail    = `john.doe@example.com`
                  iv_manager = `CN=Boss\, Anna,OU=Staff,DC=corp,DC=example,DC=com` ).
  ENDMETHOD.


  METHOD lookup.
    DATA(lo_cut) = NEW ltd_lookup( io_ldap       = mo_ldap
                                   iv_base_dn    = gc_base
                                   iv_key_type   = iv_key_type
                                   iv_batch_size = 2 ).
    rt_result = lo_cut->zif_ur_manager_lookup~get_managers( it_users ).
    cl_abap_unit_assert=>assert_false( act = mo_ldap->mv_bound msg = `LDAP connection not released` ).
  ENDMETHOD.


  METHOD resolves_manager.
    DATA(lt_result) = lookup( VALUE #( ( bname = 'JDOE' ) ) ).
    DATA(ls_result) = lt_result[ 1 ].

    cl_abap_unit_assert=>assert_equals( act = ls_result-status   exp = zif_ur_manager_lookup=>gc_status-ok ).
    cl_abap_unit_assert=>assert_equals( act = ls_result-ad_sam   exp = `JDOE` ).
    cl_abap_unit_assert=>assert_equals( act = ls_result-mgr_sam  exp = `ABOSS` ).
    cl_abap_unit_assert=>assert_equals( act = ls_result-mgr_mail exp = `anna.boss@example.com` ).
    cl_abap_unit_assert=>assert_equals( act = ls_result-mgr_bname exp = 'ABOSS' ).
  ENDMETHOD.


  METHOD unknown_user.
    DATA(lt_result) = lookup( VALUE #( ( bname = 'NOBODY' ) ) ).
    DATA(ls_result) = lt_result[ 1 ].

    cl_abap_unit_assert=>assert_equals( act = ls_result-status exp = zif_ur_manager_lookup=>gc_status-not_found ).
  ENDMETHOD.


  METHOD user_without_manager.
    DATA(lt_result) = lookup( VALUE #( ( bname = 'ABOSS' ) ) ).
    DATA(ls_result) = lt_result[ 1 ].

    cl_abap_unit_assert=>assert_equals( act = ls_result-status exp = zif_ur_manager_lookup=>gc_status-no_manager ).
  ENDMETHOD.


  METHOD manager_outside_base.
    mo_ldap->add( iv_dn      = `CN=Ext,OU=Staff,DC=corp,DC=example,DC=com`
                  iv_sam     = `EXT`
                  iv_manager = `CN=Gone,OU=Old,DC=corp,DC=example,DC=com` ).

    DATA(lt_result) = lookup( VALUE #( ( bname = 'EXT' ) ) ).
    DATA(ls_result) = lt_result[ 1 ].

    cl_abap_unit_assert=>assert_equals( act = ls_result-status exp = zif_ur_manager_lookup=>gc_status-manager_unresolved ).
    cl_abap_unit_assert=>assert_equals( act = ls_result-mgr_dn exp = `CN=Gone,OU=Old,DC=corp,DC=example,DC=com` ).
  ENDMETHOD.


  METHOD ambiguous_mail.
    mo_ldap->add( iv_dn   = `CN=Doe\, John (Admin),OU=Admins,DC=corp,DC=example,DC=com`
                  iv_sam  = `ADM_JDOE`
                  iv_mail = `john.doe@example.com` ).

    DATA(lt_result) = lookup( iv_key_type = zif_ur_manager_lookup=>gc_key_type-mail
                              it_users    = VALUE #( ( bname = 'JDOE' email = 'John.Doe@example.com' ) ) ).
    DATA(ls_result) = lt_result[ 1 ].

    cl_abap_unit_assert=>assert_equals( act = ls_result-status exp = zif_ur_manager_lookup=>gc_status-ambiguous ).
  ENDMETHOD.


  METHOD disabled_manager.
    mo_ldap->add( iv_dn  = `CN=Left,OU=Staff,DC=corp,DC=example,DC=com`
                  iv_sam = `LEFT`
                  iv_uac = `514` ).
    mo_ldap->add( iv_dn      = `CN=Orphan,OU=Staff,DC=corp,DC=example,DC=com`
                  iv_sam     = `ORPHAN`
                  iv_manager = `CN=Left,OU=Staff,DC=corp,DC=example,DC=com` ).

    DATA(lt_result) = lookup( VALUE #( ( bname = 'ORPHAN' ) ) ).
    DATA(ls_result) = lt_result[ 1 ].

    cl_abap_unit_assert=>assert_equals( act = ls_result-status       exp = zif_ur_manager_lookup=>gc_status-ok ).
    cl_abap_unit_assert=>assert_equals( act = ls_result-mgr_disabled exp = abap_true ).
  ENDMETHOD.


  METHOD keeps_input_order.
    DATA(lt_result) = lookup( VALUE #( ( bname = 'JDOE' ) ( bname = 'NOBODY' ) ( bname = 'ABOSS' ) ) ).

    cl_abap_unit_assert=>assert_equals( act = lines( lt_result ) exp = 3 ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-bname exp = 'JDOE' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-bname exp = 'NOBODY' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 3 ]-bname exp = 'ABOSS' ).
  ENDMETHOD.


  METHOD batches_queries.
    " 3 distinct users with batch size 2 -> 2 account queries + 1 manager query
    lookup( VALUE #( ( bname = 'JDOE' ) ( bname = 'ABOSS' ) ( bname = 'NOBODY' ) ( bname = 'JDOE' ) ) ).

    cl_abap_unit_assert=>assert_equals( act = mo_ldap->mv_searches exp = 3 ).
  ENDMETHOD.


  METHOD escapes_filter_values.
    cl_abap_unit_assert=>assert_equals(
      act = zcl_ur_ad_manager_lookup=>escape_filter_value( `CN=Doe\, J*hn (x)` )
      exp = `CN=Doe\5c, J\2ahn \28x\29` ).
  ENDMETHOD.

ENDCLASS.
