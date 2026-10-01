FUNCTION z_ur_get_ad_managers.
*"----------------------------------------------------------------------
*"*"Local Interface:   (function group ZUR_AD, processing type: Remote-Enabled)
*"  IMPORTING
*"     VALUE(IV_LDAP_SERVER) TYPE  LDAPSERVER-SERVERID
*"     VALUE(IV_BASE_DN) TYPE  STRING
*"     VALUE(IV_KEY_TYPE) TYPE  CHAR4 DEFAULT 'SAM'
*"     VALUE(IT_USERS) TYPE  ZUR_T_AD_USER
*"  EXPORTING
*"     VALUE(ET_RESULTS) TYPE  ZUR_T_AD_MANAGER
*"  EXCEPTIONS
*"      NO_AUTHORITY
*"      LDAP_ERROR
*"----------------------------------------------------------------------
* Determines the AD line manager of the given SAP users.
* Remote-enabled so the user review tool can call it from the CUA central
* system (or wherever the LDAP connector runs) via RFC.

  " Manager data is personal data: require display authorization for user master records
  AUTHORITY-CHECK OBJECT 'S_USER_GRP'
    ID 'CLASS' DUMMY
    ID 'ACTVT' FIELD '03'.
  IF sy-subrc <> 0.
    MESSAGE 'No authorization to display user master data' TYPE 'E' RAISING no_authority.
  ENDIF.

  TRY.
      DATA(lo_lookup) = zcl_ur_ad_manager_lookup=>create(
        iv_server_id = iv_ldap_server
        iv_base_dn   = iv_base_dn
        iv_key_type  = iv_key_type ).

      DATA(lt_results) = lo_lookup->get_managers(
        CORRESPONDING zif_ur_manager_lookup=>tt_user( it_users ) ).

      et_results = CORRESPONDING #( lt_results ).

    CATCH zcx_ur_ad_error INTO DATA(lx_error).
      DATA(lv_message) = lx_error->get_text( ).
      MESSAGE lv_message TYPE 'E' RAISING ldap_error.
  ENDTRY.

ENDFUNCTION.
