program CompileError;

{$APPTYPE CONSOLE}

begin
  // Intentional E2003: Undeclared identifier.
  Writeln(UndefinedExampleValue);
end.
