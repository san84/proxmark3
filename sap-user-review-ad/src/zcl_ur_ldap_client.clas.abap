"! LDAP access through SAP's LDAP connector (function modules LDAP_*).
"! The server and its technical "system user" are maintained in transaction LDAP.
"!
"! The structure component names of LDAP_READ's result table (LDAPETAB) vary
"! slightly between releases, so the result is read generically. All calls to
"! the LDAP_* function modules are in this class; if your release's interface
"! differs (check in SE37), this is the only place to adjust.
CLASS zcl_ur_ldap_client DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_ur_ldap_client.

    "! @parameter iv_server_id | LDAP server ID from transaction LDAP
    METHODS constructor
      IMPORTING
        iv_server_id TYPE ldapserver-serverid.

  PRIVATE SECTION.
    DATA mv_server_id TYPE ldapserver-serverid.
    DATA mv_bound     TYPE abap_bool.

    "! Reference to the first existing component of is_struct out of it_names
    CLASS-METHODS component
      IMPORTING
        is_struct       TYPE any
        it_names        TYPE string_table
      RETURNING
        VALUE(rr_comp)  TYPE REF TO data.

    CLASS-METHODS to_string
      IMPORTING
        iv_value        TYPE any
      RETURNING
        VALUE(rv_value) TYPE string.
ENDCLASS.


CLASS zcl_ur_ldap_client IMPLEMENTATION.

  METHOD constructor.
    mv_server_id = iv_server_id.
  ENDMETHOD.


  METHOD zif_ur_ldap_client~bind.
    DATA lv_ldaprc TYPE ldaprc.

    IF mv_bound = abap_true.
      RETURN.
    ENDIF.

    " Binds with the system user maintained for the server in transaction LDAP,
    " so no AD credentials are stored in code or passed around.
    CALL FUNCTION 'LDAP_SYSTEMBIND'
      EXPORTING
        serverid     = mv_server_id
      IMPORTING
        ldaprc       = lv_ldaprc
      EXCEPTIONS
        no_authoriz  = 1
        config_error = 2
        nomore_conns = 3
        ldap_failure = 4
        not_alive    = 5
        other_error  = 6
        OTHERS       = 7.
    DATA(lv_subrc) = sy-subrc.
    IF lv_subrc <> 0 OR lv_ldaprc <> 0.
      RAISE EXCEPTION TYPE zcx_ur_ad_error
        EXPORTING
          iv_text   = |Bind to LDAP server { mv_server_id } failed (exception { lv_subrc })|
          iv_ldaprc = lv_ldaprc.
    ENDIF.
    mv_bound = abap_true.
  ENDMETHOD.


  METHOD zif_ur_ldap_client~search.
    DATA lt_attributes TYPE ldapastab.
    DATA lt_entries    TYPE ldapetab.
    DATA lv_ldaprc     TYPE ldaprc.
    FIELD-SYMBOLS:
      <ls_line>  TYPE any,
      <lv_field> TYPE any,
      <ls_entry> TYPE any,
      <lt_attrs> TYPE ANY TABLE,
      <ls_attr>  TYPE any,
      <lt_vals>  TYPE ANY TABLE,
      <ls_val>   TYPE any.

    IF mv_bound = abap_false.
      RAISE EXCEPTION TYPE zcx_ur_ad_error
        EXPORTING iv_text = `LDAP search without bind`.
    ENDIF.

    " Requested attributes; the line type is flat in some releases, a structure in others
    LOOP AT it_attributes INTO DATA(lv_attribute).
      APPEND INITIAL LINE TO lt_attributes ASSIGNING <ls_line>.
      ASSIGN COMPONENT 1 OF STRUCTURE <ls_line> TO <lv_field>.
      IF sy-subrc <> 0.
        ASSIGN <ls_line> TO <lv_field>.
      ENDIF.
      <lv_field> = lv_attribute.
    ENDLOOP.

    CALL FUNCTION 'LDAP_READ'
      EXPORTING
        base         = iv_base_dn
        scope        = 2            " subtree
        filter       = iv_filter
        attributes   = lt_attributes
      IMPORTING
        entries      = lt_entries
        ldaprc       = lv_ldaprc
      EXCEPTIONS
        no_authoriz  = 1
        conn_outdate = 2
        ldap_failure = 3
        not_alive    = 4
        other_error  = 5
        OTHERS       = 6.
    DATA(lv_subrc) = sy-subrc.
    IF lv_subrc <> 0 OR lv_ldaprc <> 0.
      RAISE EXCEPTION TYPE zcx_ur_ad_error
        EXPORTING
          iv_text   = |LDAP search failed (exception { lv_subrc }), filter { iv_filter }|
          iv_ldaprc = lv_ldaprc.
    ENDIF.

    LOOP AT lt_entries ASSIGNING <ls_entry>.
      DATA(ls_entry) = VALUE zif_ur_ldap_client=>ty_entry( ).

      DATA(lr_dn) = component( is_struct = <ls_entry> it_names = VALUE #( ( `DN` ) ) ).
      IF lr_dn IS BOUND.
        ASSIGN lr_dn->* TO <lv_field>.
        ls_entry-dn = to_string( <lv_field> ).
      ENDIF.

      DATA(lr_attrs) = component( is_struct = <ls_entry> it_names = VALUE #( ( `ATTRIBUTES` ) ( `ATTRS` ) ) ).
      IF lr_attrs IS BOUND.
        ASSIGN lr_attrs->* TO <lt_attrs>.
        LOOP AT <lt_attrs> ASSIGNING <ls_attr>.
          DATA(ls_attribute) = VALUE zif_ur_ldap_client=>ty_attribute( ).

          DATA(lr_name) = component( is_struct = <ls_attr> it_names = VALUE #( ( `NAME` ) ( `TYPE` ) ) ).
          IF lr_name IS NOT BOUND.
            CONTINUE.
          ENDIF.
          ASSIGN lr_name->* TO <lv_field>.
          ls_attribute-name = to_lower( to_string( <lv_field> ) ).

          DATA(lr_vals) = component( is_struct = <ls_attr> it_names = VALUE #( ( `VALS` ) ( `VALUES` ) ) ).
          IF lr_vals IS BOUND.
            ASSIGN lr_vals->* TO <lt_vals>.
            LOOP AT <lt_vals> ASSIGNING <ls_val>.
              DATA(lr_val) = component( is_struct = <ls_val> it_names = VALUE #( ( `VAL` ) ( `VALUE` ) ) ).
              IF lr_val IS BOUND.
                ASSIGN lr_val->* TO <lv_field>.
              ELSE.
                ASSIGN <ls_val> TO <lv_field>.
              ENDIF.
              APPEND to_string( <lv_field> ) TO ls_attribute-values.
            ENDLOOP.
          ENDIF.

          INSERT ls_attribute INTO TABLE ls_entry-attributes.
        ENDLOOP.
      ENDIF.

      APPEND ls_entry TO rt_entries.
    ENDLOOP.
  ENDMETHOD.


  METHOD zif_ur_ldap_client~unbind.
    IF mv_bound = abap_false.
      RETURN.
    ENDIF.
    CALL FUNCTION 'LDAP_UNBIND'
      EXCEPTIONS
        OTHERS = 1.
    CLEAR mv_bound.
  ENDMETHOD.


  METHOD component.
    FIELD-SYMBOLS <lv_comp> TYPE any.

    LOOP AT it_names INTO DATA(lv_name).
      ASSIGN COMPONENT lv_name OF STRUCTURE is_struct TO <lv_comp>.
      IF sy-subrc = 0.
        GET REFERENCE OF <lv_comp> INTO rr_comp.
        RETURN.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD to_string.
    DATA lv_kind TYPE c LENGTH 1.

    DESCRIBE FIELD iv_value TYPE lv_kind.
    IF lv_kind = 'y' OR lv_kind = 'X'.
      " Binary value: drop the padding of fixed-length raw fields, decode UTF-8
      DATA(lv_xvalue) = CONV xstring( iv_value ).
      DATA(lv_length) = xstrlen( lv_xvalue ).
      WHILE lv_length > 0.
        DATA(lv_last) = lv_length - 1.
        IF lv_xvalue+lv_last(1) <> '00'.
          EXIT.
        ENDIF.
        lv_length = lv_last.
      ENDWHILE.
      lv_xvalue = lv_xvalue(lv_length).
      TRY.
          rv_value = cl_abap_codepage=>convert_from( lv_xvalue ).
        CATCH cx_root.
          CLEAR rv_value.
      ENDTRY.
    ELSE.
      rv_value = iv_value.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
