program HelloGate;

{$APPTYPE CONSOLE}

uses
  HelloGate.Greeting in 'src\HelloGate.Greeting.pas';

begin
  Writeln(GreetingText);
end.
