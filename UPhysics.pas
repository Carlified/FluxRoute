unit UPhysics;

// Physical conversions for PTL routing checks. Pure functions only.

interface

// Resonant length of a PTL segment: Lr = speed / (2*f), where speed = 1/delay
// (delay in ps/um) and f is the clock frequency (GHz). With those units the
// result is in um: Lr = 500 / (f_GHz * delay_ps_per_um).
const
  ResonantSpeedConstant = 500.0; // folds the /2 (from speed/(2f)) into the units
function ResonantLengthUm(FreqGHz, DelayPsPerUm: Double): Double;

// Propagation delay of a wire (um) at the given PTL delay, in ps.
function WireDelayPs(LengthUm, DelayPsPerUm: Double): Double;

implementation

function ResonantLengthUm(FreqGHz, DelayPsPerUm: Double): Double;
begin
  Result := ResonantSpeedConstant / (FreqGHz * DelayPsPerUm);
end;

function WireDelayPs(LengthUm, DelayPsPerUm: Double): Double;
begin
  Result := LengthUm * DelayPsPerUm;
end;

end.
