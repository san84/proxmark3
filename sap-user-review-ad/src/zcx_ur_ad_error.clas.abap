"! Error while reading manager information from Active Directory
CLASS zcx_ur_ad_error DEFINITION
  PUBLIC
  INHERITING FROM cx_static_check
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    DATA mv_text   TYPE string READ-ONLY.
    DATA mv_ldaprc TYPE i READ-ONLY.

    METHODS constructor
      IMPORTING
        textid    LIKE textid OPTIONAL
        previous  LIKE previous OPTIONAL
        iv_text   TYPE string OPTIONAL
        iv_ldaprc TYPE i OPTIONAL.

    METHODS get_text REDEFINITION.
ENDCLASS.


CLASS zcx_ur_ad_error IMPLEMENTATION.

  METHOD constructor ##ADT_SUPPRESS_GENERATION.
    super->constructor( textid = textid previous = previous ).
    mv_text   = iv_text.
    mv_ldaprc = iv_ldaprc.
  ENDMETHOD.

  METHOD get_text.
    result = COND #( WHEN mv_text IS NOT INITIAL THEN mv_text ELSE super->get_text( ) ).
    IF mv_ldaprc <> 0.
      result = |{ result } (LDAP return code { mv_ldaprc })|.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
