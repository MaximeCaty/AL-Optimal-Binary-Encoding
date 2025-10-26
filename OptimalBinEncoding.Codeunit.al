codeunit 51008 "TOO Optimal Bin. Encoding"
{
    /*
        Optimal binary encoding 
        
        Offer function to write and read values with dynamic byte length encoding (similar as ZigZag)
        Significantly reduce the number of byte needed to store data such as small and zero values.
        You can expect length reduction of 20-40% when writting dataset with a lot of small or undefined values
    */

    // Global scope on thoses variable help the performance for intensive function calling
    // it reduce the number of memory operation regarding allocations
    var
        ZeroByte: Byte;
        ZigZagBaseDate: Date;
        ZigZagBaseTime: Time;
        Math: Codeunit Math;
        EvalInt: Integer;
        EvalDate: Date;
        EvalTime: Time;

    procedure Initialize()
    begin
        Initialize(DMY2Date(1, 1, 2030));
    end;

    procedure Initialize(BaseDate: Date)
    var
    begin
        ZeroByte := 0;

        // Reading must function must be used with he same option as the datas were written
        // If not, run time error will occur, or give completly wrong value

        // The Base date strongly impact the number of bytes used for dates
        // 2 bytes date cover +/- 89y from specified base date
        // Its not recommanded to keep default AL base date (1.1.1753) because any date >1.1.1842 need 3 bytes
        ZigZagBaseDate := BaseDate;

        // Applying ZigZag on time does not impact much byte reduction, only when it is undefined (one zero byte)
        // (3 bytes  cover 1h10 +/- from 12, and 2 bytes just few seconds)
        // Most of value will use the 4 bytes unless it is undefined (one zero byte)
        // Base time must mid day in order to use the sign bit
        ZigZagBaseTime := 120000T;
    end;


    #region Date
    procedure WriteDate(var OutStr: OutStream; Value: Date)
    begin
        if Value = 0D then
            OutStr.Write(ZeroByte) // fast path empty date - no need to write the flag "closed"
        else begin
            // Closing date flag
            if Value = ClosingDate(Value) then begin
                WriteInt(OutStr, -1);
                EvalInt := (NormalDate(Value) - ZigZagBaseDate);
            end else
                EvalInt := (Value - ZigZagBaseDate);

            // Difference from start date (-/+ in days)
            if EvalInt >= 0 then
                WriteInt(OutStr, EvalInt + 1) // transform 0 difference to 1, to keep 0 for undefined date
            else
                WriteInt(OutStr, EvalInt - 1); // transform -1 et -2, to keep -1 for "Closing date" flag
        end;
    end;

    procedure ReadDate(var InStr: InStream; var Value: Date)
    var
        ClosedDate: Boolean;
    begin
        ReadInt(InStr, EvalInt);
        // Empty date
        if EvalInt = 0 then exit;

        // "Closed date" flag, Date value is on next integer
        if EvalInt = -1 then begin
            ReadInt(InStr, EvalInt);
            ClosedDate := true;
        end;

        // Calc difference from base date
        if EvalInt > 0 then
            Value := ZigZagBaseDate + EvalInt - 1 // 1 is base date
        else
            Value := ZigZagBaseDate + EvalInt + 1; // -1 is closing flag
        if ClosedDate then
            Value := ClosingDate(Value);
    end;
    #endregion

    #region Tim
    procedure WriteTime(var OutStr: OutStream; Value: Time)
    begin
        if Value = 0T then
            OutStr.Write(ZeroByte);
        EvalInt := Value - ZigZagBaseTime;
        if EvalInt >= 0 then
            WriteInt(OutStr, EvalInt + 1) // keep the 0 for undefined time
        else
            WriteInt(OutStr, EvalInt);
    end;

    procedure ReadTime(var InStr: InStream; var Value: Time)
    begin
        ReadInt(InStr, EvalInt);
        if EvalInt = 0 then
            exit;
        if EvalInt > 0 then
            Value := ZigZagBaseTime + EvalInt - 1
        else
            Value := ZigZagBaseTime + EvalInt;
    end;
    #endregion

    #region Datetime
    procedure WriteDateTime(var OutStr: OutStream; Value: DateTime)
    begin
        WriteDate(OutStr, DT2Date(Value)); // date
        WriteTime(OutStr, DT2Time(Value));  // time
    end;

    procedure ReadDateTime(var InStr: InStream; var Value: DateTime)
    begin
        ReadDate(InStr, EvalDate); // date
        ReadTime(InStr, EvalTime); // time
        Value := CreateDateTime(EvalDate, EvalTime);
    end;
    #endregion

    #region Integer

    // Write encoded Integer using ZigZag (use 1-4 bytes instead of fixed 4 bytes)
    procedure WriteInt(var OutStr: OutStream; Value: Integer)
    var
        u: Decimal;   // unsigned zig-zag value (0 … 4 294 967 295)
        b: Byte;      // byte we write
    begin
        // ---- Zig-Zag (safe in Decimal) ----
        if Value = 0 then begin
            // fast path, one 0 byte
            OutStr.Write(ZeroByte);
            exit;
        end;

        u := Value;
        if u >= 0 then
            u := u * 2
        else
            u := u * -2 - 1;

        // ---- Encode loop (max 5 iterations) ----
        repeat
            b := u mod 128;                 // low 7 bits
            u := u div 128; // integer division u := Round(u / 128, 1, '<');    // floor-divide (next chunk)
            if u > 0 then
                b += 128;                   // set continuation bit
            OutStr.Write(b);
        until u = 0;
    end;

    // Read encoded Integer using ZigZag (use 1-4 bytes instead of fixed 4 bytes)
    procedure ReadInt(var InStr: InStream; var Value: Integer)
    var
        u: Decimal;   // accumulated unsigned value
        mul: Decimal; // 128^shift
        b: Byte;      // byte read from stream
    begin
        // Read first byte
        InStr.Read(b);

        // ---- Fast path: single byte = 0 ----
        if b = 0 then begin
            Value := 0;
            exit;
        end;

        // Initialize accumulator using the first byte
        u := b mod 128;
        mul := 128;

        // Continue if continuation bit set
        while b >= 128 do begin
            InStr.Read(b);
            u += (b mod 128) * mul;
            mul *= 128;
        end;

        // ---- Un-Zig-Zag ----
        if (u mod 2) = 0 then
            Value := u div 2
        else
            Value := -((u + 1) div 2);
    end;
    #endregion

    #region BigInteger
    procedure WriteBigInt(var OutStr: OutStream; Value: BigInteger)
    var
        LowPart, HighPart : Integer;
    begin
        // Fast path: for 0 bytes
        if Value = 0 then begin
            OutStr.Write(ZeroByte);
            OutStr.Write(ZeroByte);
            exit;
        end;

        // Split BigInteger into Low and High 32-bit parts
        SplitBigIntegerToTwoInt32(Value, LowPart, HighPart); // Lower 31 bits // Upper 33 bits (signed)

        // Write Low then High as varint
        WriteInt(OutStr, LowPart);
        WriteInt(OutStr, HighPart);
    end;

    procedure ReadBigInt(var InStr: InStream; var Value: BigInteger)
    var
        LowPart, HighPart : Integer;
    begin
        ReadInt(InStr, LowPart);
        ReadInt(InStr, HighPart);

        // Reconstruct with LowPart as unsigned 32-bit
        if LowPart < 0 then
            Value := HighPart * 4294967296L + LowPart + 4294967296L
        else
            Value := HighPart * 4294967296L + LowPart;
    end;
    #endregion

    #region Decimal
    procedure WriteDecimal(var OutStr: OutStream; Value: Decimal)
    var
        ValStr: Text[100];
        MantBig: BigInteger;
        Scale: Byte;
    begin
        // Fast path: for 0 bytes
        if Value = 0 then begin
            OutStr.Write(Scale); // scale
            OutStr.Write(ZeroByte); // mantissa (BigInt)
            OutStr.Write(ZeroByte);
            exit;
        end;

        // Write the mantissa with the max number of supported decimal for storage in AL (18, it go further only for calculation)
        ValStr := Format(Value, 0, '<Sign><Integer><Decimals,28>');

        // Find decimal point position
        if ValStr.Contains('.') then begin
            ValStr := ValStr.TrimEnd('0');
            Scale := StrLen(ValStr) - StrPos(ValStr, '.');
            if Scale > 18 then
                Error(StrSubstNo('Overflow of scale while encoding zigzag decimal, maximum supported value is 18, value scale : %1', Scale));
            ValStr := ValStr.Replace('.', '').TrimStart('0');
            if ValStr = '' then // there is factrionnal lower than 18 digits - cannot be proceed with format
                MantBig := 0
            else
                Evaluate(MantBig, ValStr);
        end else
            Evaluate(MantBig, ValStr);

        OutStr.Write(Scale); // scale as Byte (0-28)
        WriteBigInt(OutStr, MantBig); // mantissa as signed BigInteger      
    end;

    procedure ReadDecimal(var InStr: InStream; var Value: Decimal)
    var
        MantBig: BigInteger;
        Scale: Byte;
    begin
        InStr.Read(Scale);
        ReadBigInt(InStr, MantBig);
        if MantBig = 0 then begin
            Value := 0;
            exit;
        end;

        // Decimal conversion
        if Scale > 0 then begin
            // Division is precise up to 18 digits (div by 1000000000000000000)
            if Scale IN [0 .. 18] then
                Value := MantBig / Math.Pow(10, Scale)
            else
                Error(StrSubstNo('Corrupted or overflow of scale while decoding zigzag decimal, maximum supported value is 18, read scale : %1', Scale));
        end else
            Value := MantBig;
    end;
    #endregion

    local procedure SplitBigIntegerToTwoInt32(Value: BigInteger; var Low: Integer; var High: Integer)
    var
        LowBig: BigInteger;
        HighBig: BigInteger;
        temp: Decimal;
    begin
        LowBig := Value MOD 4294967296L;
        HighBig := Value DIV 4294967296L;
        if LowBig < 0 then begin
            LowBig += 4294967296L;
            HighBig -= 1;
        end;
        temp := LowBig;
        if temp >= 2147483648.0 then
            Low := temp - 4294967296.0
        else
            Low := temp;
        temp := HighBig;
        if temp >= 2147483648.0 then
            High := temp - 4294967296.0
        else
            High := temp;
    end;
}
