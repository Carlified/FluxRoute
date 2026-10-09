unit UNetNaming;

// Single source of truth for the net-naming conventions used to classify nets
// (clock network vs signal vs bias vs validation-inserted buffers). These names
// are produced by ClockNetwork.pas / the routing validation and consumed by the
// routing filters, so the literals must agree.

interface

const
  ClockRootName = 'clk';          // root clock net
  ClockRowPrefix = 'clk_row_';    // per-row tap net: clk_row_<level>
  ClockSpinePrefix = 'clk_spine_'; // trunk tap net: clk_spine_<idx>
  ClockDelayPrefix = 'clk_delay_'; // spine delay/buffer chain
  ClockBufferMarker = '__clkbuf_'; // balancing-buffer output: <Leaf>__clkbuf_<n>
  BiasPrefix = 'bias_';           // constant-voltage distribution lines
  BiasTrunkName = 'bias_trunk';   // the far-left bias trunk wire
  ValidationBufferMarker = '__vbuf_'; // validation-inserted buffer net

// A clock-network net: the root/row/spine/delay nets ('clk*') or a balancing
// buffer's output net ('__clkbuf_' marker - those are named after the leaf they
// feed and do NOT start with 'clk').
function IsClockNetName(const Name: string): Boolean;

// A bias (constant-voltage) distribution line.
function IsBiasNetName(const Name: string): Boolean;

// Name builders (must match the consumers above).
function ClockRowNetName(Level: Integer): string;
function ClockSpineNetName(Index: Integer): string;
function ClockDelayNetName(Index: Integer): string;
function ClockDelayBufNetName(Index, Stage: Integer): string;
function ClockBufNetName(const BaseName: string; Index: Integer): string;
function ValidationBufNetName(const BaseName: string; Index: Integer): string;

implementation

uses
  System.SysUtils, System.StrUtils;

function IsClockNetName(const Name: string): Boolean;
begin
  Result := StartsText(ClockRootName, Name) or (Pos(ClockBufferMarker, Name) > 0);
end;

function IsBiasNetName(const Name: string): Boolean;
begin
  Result := StartsText(BiasPrefix, Name);
end;

function ClockRowNetName(Level: Integer): string;
begin
  Result := Format(ClockRowPrefix + '%d', [Level]);
end;

function ClockSpineNetName(Index: Integer): string;
begin
  Result := Format(ClockSpinePrefix + '%d', [Index]);
end;

function ClockDelayNetName(Index: Integer): string;
begin
  Result := Format(ClockDelayPrefix + '%d', [Index]);
end;

function ClockDelayBufNetName(Index, Stage: Integer): string;
begin
  Result := Format(ClockDelayPrefix + '%d_buf_%d', [Index, Stage]);
end;

function ClockBufNetName(const BaseName: string; Index: Integer): string;
begin
  Result := Format('%s%s%d', [BaseName, ClockBufferMarker, Index]);
end;

function ValidationBufNetName(const BaseName: string; Index: Integer): string;
begin
  Result := Format('%s%s%d', [BaseName, ValidationBufferMarker, Index]);
end;

end.
