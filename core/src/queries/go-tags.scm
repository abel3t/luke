; Imports
(import_spec
  path: (interpreted_string_literal) @import.path) @import

; Functions
(function_declaration
  name: (identifier) @function.name) @definition.function

; Methods
(method_declaration
  name: (field_identifier) @method.name) @definition.method

; Types (Structs, Interfaces)
(type_spec
  name: (type_identifier) @class.name) @definition.class
