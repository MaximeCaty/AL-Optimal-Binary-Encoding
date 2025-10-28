codeunit 51008 "TOO Optimal Bin. Encoding"
{
    /*
        Optimal binary encoding 
        
        Offer function to write and read values in stream with dynamic byte length encoding (similar as ZigZag)
        Significantly reduce the number of byte needed to store numerical values
        You can expect length reduction of 20-40% when writting dataset with a lot of small or undefined values
    */

    // Global scope on thoses variable help the performance for intensive function calling
    // it reduce the number of memory operation regarding allocations
    SingleInstance = true;

    var
        ZeroByte: Byte;
        OneBye: Byte;
        ZigZagBaseDate: Date;
        ZigZagBaseTime: Time;
        Math: Codeunit Math;
        EvalInt: Integer;
        EvalDate: Date;
        EvalTime: Time;
        EvalByte: Byte;

    procedure Initialize()
    begin
        Initialize(DMY2Date(1, 1, 2030));
    end;

    procedure Initialize(BaseDate: Date)
    var
    begin
        ZeroByte := 0;
        OneBye := 1;

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

    procedure WriteBool(var OutStr: OutStream; Value: Boolean)
    begin
        if Value then
            OutStr.Write(ZeroByte)
        else
            OutStr.Write(OneBye);
    end;

    procedure ReadBool(var InStr: InStream; var Value: Boolean)
    begin
        InStr.Read(EvalByte);
        if EvalByte = 1 then
            Value := true
        else
            Value := false;
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
        if Value = 0DT then begin
            OutStr.Write(ZeroByte); // empty date
            OutStr.Write(ZeroByte); // empty time
            exit;
        end;
        WriteDate(OutStr, DT2Date(Value)); // date
        WriteTime(OutStr, DT2Time(Value));  // time
    end;

    procedure ReadDateTime(var InStr: InStream; var Value: DateTime)
    begin
        ReadDate(InStr, EvalDate); // date
        ReadTime(InStr, EvalTime); // time
        if (EvalDate = 0D) and (EvalTime = 0T) then exit;
        Value := CreateDateTime(EvalDate, EvalTime);
    end;
    #endregion

    #region Integer

    // Write encoded Integer using ZigZag (use 1-4 bytes instead of fixed 4 bytes)
    procedure WriteInt(var OutStr: OutStream; Value: Integer)
    var
        u: BigInteger;   // unsigned zig-zag value (0 … 4 294 967 295)
        b: Byte;      // byte we write
    begin
        // ---- Zig-Zag (safe in Decimal) ----
        if Value = 0 then begin
            // fast path, one 0 byte
            OutStr.Write(ZeroByte);
            exit;
        end;

        if u >= 0 then
            u := Value * 2
        else
            u := Value * -2 - 1;

        // ---- Encode loop (max 5 iterations) ----
        repeat
            b := u mod 128;                 // low 7 bits
            u := u div 128;                 // floor-divide (next chunk)
            if u > 0 then
                b += 128;                   // set continuation bit
            OutStr.Write(b);
        until u = 0;
    end;

    // Read encoded Integer using ZigZag (use 1-4 bytes instead of fixed 4 bytes)
    procedure ReadInt(var InStr: InStream; var Value: Integer)
    var
        u: BigInteger;   // accumulated unsigned value
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
        absValue: BigInteger;
        low6: Integer;      // low 6 bits of abs(value)
        remaining: BigInteger;   // high part after low6
        b: Byte;
    begin
        if Value = 0 then begin
            OutStr.Write(ZeroByte);
            exit;
        end;

        if Value < 0 then
            absValue := -Value                 // safe after min-check
        else
            absValue := Value;

        // ----- low 6 bits → zigzag (fits in Integer) -----
        low6 := (absValue mod 64) * 2;          // 0 … 126
        if Value < 0 then
            low6 -= 1;                          // 0 … 126 → -1 … 125
        remaining := absValue div 64;           // high part
        if low6 < 0 then begin                  // borrow from high part
            low6 += 128;
            remaining -= 1;
        end;
        b := low6;                              // first byte (7 data bits + cont)
        if remaining > 0 then
            b += 128;                           // set continuation bit
        OutStr.Write(b);

        // ----- remaining high part – standard LEB128 (8-bit final) -----
        while remaining > 0 do begin
            b := remaining mod 128;
            remaining := remaining div 128;
            if remaining > 0 then
                b += 128;                       // continuation bit
            OutStr.Write(b);
        end;
    end;

    procedure ReadBigInt(var InStr: InStream; var Value: BigInteger)
    var
        low7: Integer;
        remaining: BigInteger;
        b: Byte;
        sign: Byte;
        multiplier: Decimal;
    begin
        InStr.Read(b);

        if b = 0 then begin
            Value := 0;
            exit;
        end;

        // ----- Extract 7 data bits: b mod 128 -----
        low7 := b mod 128;

        // ----- Sign bit: low7 mod 2 -----
        sign := low7 mod 2;

        // ----- Low 6 bits of abs(value): (low7 + sign) div 2 -----
        low7 := (low7 + sign) div 2;

        // ----- Read continuation bytes (7 bits each) -----
        multiplier := 1;
        while b >= 128 do begin
            InStr.Read(b);
            remaining += (b mod 128) * multiplier;
            multiplier *= 128;
        end;

        // ----- Reconstruct absolute value -----
        Value := low7 + 64 * remaining;

        // ----- Apply sign -----
        if sign = 1 then
            Value := -Value;
    end;
    #endregion

    #region Decimal
    procedure WriteDecimal(var OutStr: OutStream; Value: Decimal)
    var
        ValStr: Text[50];
        MantBig: BigInteger;
        Scale: Byte;
    begin
        // Fast path: for 0 bytes
        if Value = 0 then begin
            OutStr.Write(Scale); // scale
            OutStr.Write(ZeroByte); // mantissa (BigInt)
            exit;
        end;

        // Write the mantissa with the max number of supported decimal for storage in AL (18, it go further only for calculation)
        ValStr := Format(Value);

        // Find decimal point position
        if ValStr.Contains('.') then begin
            ValStr := ValStr.TrimEnd('0');
            Scale := StrLen(ValStr) - StrPos(ValStr, '.');
            if Scale > 18 then
                Error(StrSubstNo('Overflow of scale while encoding zigzag decimal, maximum supported value is 18, value scale : %1', Scale));
            ValStr := ValStr.TrimStart('0').Replace('.', '');
        end;
        Evaluate(MantBig, ValStr);

        OutStr.Write(Scale);          // scale as Byte (0-18)
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
        case Scale of
            0:
                Value := MantBig;
            // Division is precise up to 18 digits (div by 1000000000000000000)
            // Case save a power operation 
            1:
                Value := MantBig / 10;
            2:
                Value := MantBig / 100;
            3:
                Value := MantBig / 1000;
            4:
                Value := MantBig / 10000;
            5:
                Value := MantBig / 100000;
            6:
                Value := MantBig / 1000000;
            7:
                Value := MantBig / 10000000;
            8:
                Value := MantBig / 100000000;
            9:
                Value := MantBig / 1000000000;
            10:
                Value := MantBig / 10000000000L;
            11:
                Value := MantBig / 100000000000L;
            12:
                Value := MantBig / 1000000000000L;
            13:
                Value := MantBig / 10000000000000L;
            14:
                Value := MantBig / 100000000000000L;
            15:
                Value := MantBig / 1000000000000000L;
            16:
                Value := MantBig / 10000000000000000L;
            17:
                Value := MantBig / 100000000000000000L;
            18:
                Value := MantBig / 1000000000000000000L;
            else
                Error(StrSubstNo('Corrupted or overflow of scale while decoding zigzag decimal, maximum supported value is 18, read scale : %1', Scale));
        end;
    end;
    #endregion
}
