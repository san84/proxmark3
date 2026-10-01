"! Minimal LDAP access used by the user review tool.
"! Decouples the lookup logic from SAP's LDAP connector so it can be unit tested.
INTERFACE zif_ur_ldap_client
  PUBLIC.

  TYPES:
    BEGIN OF ty_attribute,
      name   TYPE string,        " always lower case, e.g. samaccountname
      values TYPE string_table,
    END OF ty_attribute,
    tt_attributes TYPE SORTED TABLE OF ty_attribute WITH UNIQUE KEY name,
    BEGIN OF ty_entry,
      dn         TYPE string,
      attributes TYPE tt_attributes,
    END OF ty_entry,
    tt_entries TYPE STANDARD TABLE OF ty_entry WITH EMPTY KEY.

  METHODS bind
    RAISING
      zcx_ur_ad_error.

  "! Subtree search below iv_base_dn
  METHODS search
    IMPORTING
      iv_base_dn       TYPE string
      iv_filter        TYPE string
      it_attributes    TYPE string_table
    RETURNING
      VALUE(rt_entries) TYPE tt_entries
    RAISING
      zcx_ur_ad_error.

  METHODS unbind.

ENDINTERFACE.
