*&---------------------------------------------------------------------*
*& Report ZUR_AD_MANAGER_REPORT
*&---------------------------------------------------------------------*
*& Shows the AD line manager of SAP users (test/standalone tool for the
*& user review). In the review tool itself, call
*& ZCL_UR_AD_MANAGER_LOOKUP or Z_UR_GET_AD_MANAGERS after the CUA
*& enrichment step.
*&---------------------------------------------------------------------*
REPORT zur_ad_manager_report.

TABLES usr02.

SELECTION-SCREEN BEGIN OF BLOCK b_users WITH FRAME TITLE TEXT-001.
  SELECT-OPTIONS s_user FOR usr02-bname.
  SELECT-OPTIONS s_class FOR usr02-class.
  PARAMETERS p_locked AS CHECKBOX DEFAULT abap_false.
SELECTION-SCREEN END OF BLOCK b_users.

SELECTION-SCREEN BEGIN OF BLOCK b_ad WITH FRAME TITLE TEXT-002.
  PARAMETERS p_server TYPE ldapserver-serverid OBLIGATORY.
  PARAMETERS p_base   TYPE c LENGTH 132 LOWER CASE OBLIGATORY.
  PARAMETERS p_sam  RADIOBUTTON GROUP key DEFAULT 'X'.
  PARAMETERS p_mail RADIOBUTTON GROUP key.
  PARAMETERS p_upn  RADIOBUTTON GROUP key.
SELECTION-SCREEN END OF BLOCK b_ad.

START-OF-SELECTION.
  " Dialog users only: system/service/communication users have no line manager
  SELECT bname, uflag
    FROM usr02
    WHERE bname IN @s_user
      AND class IN @s_class
      AND ustyp =  'A'
    ORDER BY bname
    INTO TABLE @DATA(lt_usr02).
  IF p_locked = abap_false.
    DELETE lt_usr02 WHERE uflag <> 0.
  ENDIF.

  IF lt_usr02 IS INITIAL.
    MESSAGE 'No users selected' TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  DATA(lv_key_type) = COND zif_ur_manager_lookup=>ty_key_type(
    WHEN p_mail = abap_true THEN zif_ur_manager_lookup=>gc_key_type-mail
    WHEN p_upn  = abap_true THEN zif_ur_manager_lookup=>gc_key_type-upn
    ELSE zif_ur_manager_lookup=>gc_key_type-sam ).

  TRY.
      DATA(lt_results) = zcl_ur_ad_manager_lookup=>create(
          iv_server_id = p_server
          iv_base_dn   = CONV #( p_base )
          iv_key_type  = lv_key_type
        )->get_managers( CORRESPONDING #( lt_usr02 ) ).
    CATCH zcx_ur_ad_error INTO DATA(lx_error).
      DATA(lv_message) = lx_error->get_text( ).
      MESSAGE lv_message TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
  ENDTRY.

  TRY.
      cl_salv_table=>factory( IMPORTING r_salv_table = DATA(lo_alv)
                              CHANGING  t_table      = lt_results ).
      lo_alv->get_functions( )->set_all( ).
      lo_alv->get_columns( )->set_optimize( ).
      lo_alv->display( ).
    CATCH cx_salv_msg INTO DATA(lx_salv).
      MESSAGE lx_salv TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.

* Text symbols:   001 SAP users   002 Active Directory
