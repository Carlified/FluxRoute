program BlifParser;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  LefLibrary in 'LefLibrary.pas',
  BlifLibrary in 'BlifLibrary.pas';

var
  Lib: TLibrary;
  Model: TBlifModel;
  Errors: TStringList;
  Gate: TGateInstance;
  Conn: TPinConnection;
  NetName: string;
  Net: TNet;
  NC: TNetConnection;
  s: string;

begin
  Lib := nil;
  Model := nil;
  Errors := TStringList.Create;
  try
    Lib := LoadLefLibrary('lef_7_metals.lef');   // change location to test
    Model := ParseBlif('blif files/full_adder.blif', Lib, Errors); // change location to test

    if Errors.Count > 0 then
    begin
      Writeln('Errors found while parsing BLIF:');
      for s in Errors do
        Writeln('  ', s);
      Writeln;
    end;

    // Connectivity checks need the whole net list built, so they run as a
    // separate pass after ParseBlif rather than inline during parsing.
    Errors.Clear;
    CheckNetConnectivity(Model, Errors);
    if Errors.Count > 0 then
    begin
      Writeln('Connectivity problems found:');
      for s in Errors do
        Writeln('  ', s);
      Writeln;
    end;

    Writeln('Model: ', Model.Name);
    Writeln('Inputs: ', Model.Inputs.CommaText);
    Writeln('Outputs: ', Model.Outputs.CommaText);
    Writeln;

    Writeln('Gates:');
    for Gate in Model.Gates do
    begin
      Writeln('   ', Gate.CellName);
      for Conn in Gate.Connections do
        Writeln('      ', Conn.PinName, ' -> ', Conn.NetName);
    end;
    Writeln;

    Writeln('Nets:');
    for NetName in Model.Nets.Keys do
    begin
      Net := Model.Nets[NetName];
      Write('   ', Net.Name, ': ');
      for NC in Net.Connections do
      begin
        if NC.IsDriver then
          Write('[drives] ')
        else
          Write('[loads] ');
        Write(NC.Gate.CellName, '.', NC.PinName, '  ');
      end;
      Writeln;
    end;

  finally
    Model.Free;
    Lib.Free;
    Errors.Free;
  end;
end.

