; Imports
(import_statement
  source: (string (string_fragment) @import.path)) @import

; Calls
(call_expression
  function: [
    (identifier) @call.name
    (member_expression property: (property_identifier) @call.name)
  ]) @call

; Classes
(class_declaration
  name: (type_identifier) @class.name) @definition.class

; Functions
(function_declaration
  name: (identifier) @function.name) @definition.function

; Methods
(method_definition
  name: (property_identifier) @method.name) @definition.method

; Arrow functions in variables
(lexical_declaration
  (variable_declarator
    name: (identifier) @function.name
    value: (arrow_function))) @definition.function

; Exports
(export_statement
  declaration: (class_declaration
    name: (type_identifier) @class.name)) @definition.export

(export_statement
  declaration: (function_declaration
    name: (identifier) @function.name)) @definition.export

(export_statement
  declaration: (lexical_declaration
    (variable_declarator
      name: (identifier) @function.name))) @definition.export

; SQL Strings inside TypeScript
(variable_declarator
  name: (identifier) @sql.name
  value: (template_string) @sql.query)
