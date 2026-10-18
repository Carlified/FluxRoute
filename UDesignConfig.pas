unit UDesignConfig;

// Parsed, form-independent snapshot of the placement/routing configuration: the
// UI fills it from the text boxes; a 0 (or '') field means unset and callers fall back.

interface

uses
  UPhysics;

type
  TDesignConfig = record
    CoreUm: Double;          // core block size
    RowHeightUm: Double;     // row height
    DieWUm: Double;          // die width
    DieHUm: Double;          // die height
    UtilizationPct: Double;  // target utilization, percent
    MaxBiasCurrentUa: Double;
    MaxBiasTrunkCurrentUa: Double; // trunk wires may carry more than one branch
    MaxPtlLengthUm: Double;
    FreqGHz: Double;         // operating frequency
    PtlDelayPsPerUm: Double; // PTL propagation delay
    PulseWidthUm: Double;    // pulse width
    BiasLayer: string;       // bias routing layer name
  end;

// Resonant length implied by the config, in um (0 if freq/delay unset).
function DesignResonantLengthUm(const C: TDesignConfig): Double;

// Core blocks per row (0 if the core size is unset).
function DesignBlocksPerRow(const C: TDesignConfig): Integer;

implementation

uses
  System.Math;

function DesignResonantLengthUm(const C: TDesignConfig): Double;
begin
  if (C.FreqGHz > 0) and (C.PtlDelayPsPerUm > 0) then
    Result := UPhysics.ResonantLengthUm(C.FreqGHz, C.PtlDelayPsPerUm)
  else
    Result := 0;
end;

function DesignBlocksPerRow(const C: TDesignConfig): Integer;
begin
  if C.CoreUm > 0 then
    Result := Round(C.RowHeightUm / C.CoreUm)
  else
    Result := 0;
end;

end.
