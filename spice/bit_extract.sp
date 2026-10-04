* Behavioral SPICE timing model for one-bit extraction datapath
.param VDD=1.0
Vdd vdd 0 {VDD}
* Address adder / decoder / mux / extractor modeled as cascaded RC stages.
Raddr in addr 1k
Caddr addr 0 20f
Rsel addr sel 1k
Csel sel 0 25f
Rext sel out 800
Cout out 0 20f
Vin in 0 PULSE(0 {VDD} 0 5p 5p 500p 1n)
.tran 1p 5n
.measure tran TPD TRIG v(in) VAL='VDD/2' RISE=1 TARG v(out) VAL='VDD/2' RISE=1
.end
