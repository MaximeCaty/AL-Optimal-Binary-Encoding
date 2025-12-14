codeunit 51008 "TOO Optimal Bin. Encoding"
{
    /*
        Optimal binary encoding 
        
        Offer function to write and read values with dynamic length encoding (LEB128+ZigZag)
        Significantly reduce the number of byte needed to store some value.
        You can expect length reduction of 20-30% when writting dataset with a lot of small or undefined values
    */

    // Global scope on thoses variable help the performance for intensive function calling
    // reduce the number of memory allocation operation
    SingleInstance = true;

    var
        ZeroByte: Byte;
        OneByte: Byte;
        ZigZagBaseDate: Date;
        ZigZagBaseTime: Time;
        Math: Codeunit Math;
        EvalInt: Integer;
        EvalDate: Date;
        EvalTime: Time;
        EvalByte: Byte;
        Scale: Byte;
        ValStr: Text[50];
        u: BigInteger;   // unsigned zig-zag value (0 … 4 294 967 295)
        mul: Decimal; // 128^shift
        low7: Integer; // low 7 bits
        low6: Integer; // low 6 bits
        remaining: BigInteger;
        sign: Byte;
        absValue: BigInteger;

    procedure Initialize()
    begin
        Initialize(DMY2Date(1, 1, 2030));
    end;

    procedure Initialize(BaseDate: Date)
    var
    begin
        ZeroByte := 0;
        OneByte := 1;

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
            OutStr.Write(OneByte);
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
            OutStr.Write(ZeroByte)
        else
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

    // Write encoded Integer using ZigZag and LEB128 encoding (use 1-4 bytes instead of fixed 4 bytes)
    procedure WriteInt(var OutStr: OutStream; Value: Integer)
    begin
        // fast path for one Zero byte
        if Value = 0 then begin
            OutStr.Write(ZeroByte);
            exit;
        end;

        // ---- Zig-Zag in BigInt (because x 2) ----
        u := Value;
        if u >= 0 then
            u := u * 2
        else
            u := u * -2 - 1;

        // ---- LEB128 Encode loop (max 5 iterations) ----
        repeat
            EvalByte := u mod 128;          // low 7 bits
            u := u div 128;                 // floor-divide (next chunk)
            if u > 0 then
                EvalByte += 128;            // set continuation bit
            OutStr.Write(EvalByte);
        until u = 0;
    end;

    // Read encoded Integer using ZigZag (use 1-4 bytes instead of fixed 4 bytes)
    procedure ReadInt(var InStr: InStream; var Value: Integer)
    begin
        // Read first byte
        InStr.Read(EvalByte);

        // ---- Fast path: single byte = 0 ----
        if EvalByte = 0 then begin
            Value := 0;
            exit;
        end;

        // Initialize accumulator using the first byte
        u := EvalByte mod 128;
        mul := 128;

        // Continue if continuation bit set
        while EvalByte >= 128 do begin
            InStr.Read(EvalByte);
            u += (EvalByte mod 128) * mul;
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
    begin
        if (Value <= 2147483647) and (Value >= -2147483647) then begin
            // Fast path for small numbers
            WriteInt(OutStr, Value);
            exit;
        end;

        // ABS value
        if Value < 0 then
            absValue := -Value
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
        EvalByte := low6;                              // first byte (7 data bits + cont)
        if remaining > 0 then
            EvalByte += 128;                           // set continuation bit
        OutStr.Write(EvalByte);

        // ----- remaining high part – standard LEB128 (8-bit final) -----
        while remaining > 0 do begin
            EvalByte := remaining mod 128;
            remaining := remaining div 128;
            if remaining > 0 then
                EvalByte += 128;                       // continuation bit
            OutStr.Write(EvalByte);
        end;
    end;

    procedure ReadBigInt(var InStr: InStream; var Value: BigInteger)
    begin
        InStr.Read(EvalByte);

        if EvalByte = 0 then begin
            Value := 0;
            exit;
        end;

        // ----- Extract 7 data bits: b mod 128 -----
        low7 := EvalByte mod 128;

        // ----- Sign bit: low7 mod 2 -----
        sign := low7 mod 2;

        // ----- Low 6 bits of abs(value): (low7 + sign) div 2 -----
        low7 := (low7 + sign) div 2;

        // ----- Read continuation bytes (7 bits each) -----
        mul := 1;
        remaining := 0;
        while EvalByte >= 128 do begin
            InStr.Read(EvalByte);
            remaining += (EvalByte mod 128) * mul;
            mul *= 128;
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
    begin
        // Fast path: for 0 bytes
        if Value = 0 then begin
            OutStr.Write(ZeroByte); // scale
            OutStr.Write(ZeroByte); // mantissa (BigInt)
            exit;
        end;

        // Write the mantissa with the max number of supported decimal for storage in AL (18, it go further only for calculation)
        if Math.Truncate(Value) = Value then begin
            OutStr.Write(ZeroByte);
            u := Value;
            if (u <= 2147483647) and (u >= -2147483647) then
                WriteInt(OutStr, u)
            else
                WriteBigInt(OutStr, u); // mantissa as signed BigInteger      
            exit;
        end;

        ValStr := Format(Value, 0, 9);

        // Find decimal point position
        if ValStr.Contains('.') then begin
            ValStr := ValStr.TrimEnd('0');
            EvalByte := StrLen(ValStr) - StrPos(ValStr, '.');
            //if Scale > 18 then
            //    Error(StrSubstNo('Overflow of scale while encoding zigzag decimal, maximum supported value is 18, value scale : %1', Scale));
            ValStr := ValStr.TrimStart('0').Replace('.', '');
        end else
            EvalByte := 0;
        Evaluate(u, ValStr);

        OutStr.Write(EvalByte); // scale as Byte (0-18)
        if (u <= 2147483647) and (u >= -2147483647) then
            WriteInt(OutStr, u)
        else
            WriteBigInt(OutStr, u); // mantissa as signed BigInteger      
    end;

    procedure ReadDecimal(var InStr: InStream; var Value: Decimal)
    begin
        InStr.Read(Scale);
        ReadBigInt(InStr, u);
        if u = 0 then begin
            Value := 0;
            exit;
        end;

        // Decimal conversion
        case Scale of
            0:
                Value := u;
            // Division is precise up to 18 digits (div by 1000000000000000000)
            // Case save a power operation 
            1:
                Value := u / 10;
            2:
                Value := u / 100;
            3:
                Value := u / 1000;
            4:
                Value := u / 10000;
            5:
                Value := u / 100000;
            6:
                Value := u / 1000000;
            7:
                Value := u / 10000000;
            8:
                Value := u / 100000000;
            9:
                Value := u / 1000000000;
            10:
                Value := u / 10000000000L;
            11:
                Value := u / 100000000000L;
            12:
                Value := u / 1000000000000L;
            13:
                Value := u / 10000000000000L;
            14:
                Value := u / 100000000000000L;
            15:
                Value := u / 1000000000000000L;
            16:
                Value := u / 10000000000000000L;
            17:
                Value := u / 100000000000000000L;
            18:
                Value := u / 1000000000000000000L;
            else
                Error(StrSubstNo('Corrupted or overflow of scale while decoding zigzag decimal, maximum supported value is 18, read scale : %1', Scale - 0));
        end;
    end;
    #endregion

    #region Tests
    local procedure TestBinEncoding()
    var
        zigzag: Codeunit "TOO Optimal Bin. Encoding";
        tempblob: codeunit "Temp Blob";
        instream: InStream;
        outstream: OutStream;
        OriginalInt: array[100000] of Integer;
        OriginalBigInt: array[100000] of BigInteger;
        ReadInt: array[100000] of Integer;
        ReadBigInt: array[100000] of BigInteger;
        OriginalDec: array[100000] of Decimal;
        ReadDec: array[100000] of Decimal;
        OriginalDate: array[100000] of Date;
        ReadDate: array[100000] of Date;
        OriginalTime: array[100000] of Time;
        ReadTime: array[100000] of Time;
        StartTime, EndTime : DateTime;
        Duration: Duration;
        CountDiff: Integer;
        i: Integer;
        Val: Integer;
        IntegerPart: BigInteger;
        Scale: Integer;
    begin
        zigzag.Initialize();

        // Generate 10000 random Integers (approximately full range -2147483647 to 2147483647)
        OriginalInt[1] := 0;
        OriginalInt[2] := 2147483647; // Max + value
        OriginalInt[3] := -2147483647; // Max - value
        OriginalInt[5] := 1234567899; // Half of + max value 
        OriginalInt[6] := -1234567899; // Half of - max value
        for i := 7 to 10000 do begin
            if Random(2) = 1 then
                Val := -Random(2147483647)
            else
                Val := Random(2147483647);
            OriginalInt[i] := Val;
        end;

        StartTime := CurrentDateTime();

        tempblob.CreateOutStream(outstream);

        // Write all Integers
        for i := 1 to 100000 do
            zigzag.WriteInt(outstream, OriginalInt[i]);

        tempblob.CreateInStream(instream);

        // Read all Integers
        for i := 1 to 100000 do
            zigzag.ReadInt(instream, ReadInt[i]);

        EndTime := CurrentDateTime();
        Duration := EndTime - StartTime;

        // Compare and count differences
        CountDiff := 0;
        for i := 1 to 100000 do
            if OriginalInt[i] <> ReadInt[i] then
                CountDiff += 1;

        Message('Batch test INTEGER completed. \ Duration: %1 ms. \ Number of differences detected: %2 \ Original size: %3 \ Encoded size : %4', Duration div 1, CountDiff, 10000 * 4, instream.Length());

        StartTime := CurrentDateTime();

        clear(tempblob);
        tempblob.CreateOutStream(outstream);

        // Generate 100000 random BigIntegers (full range -2^63 to 2^63-1)
        OriginalBigInt[1] := 0L;
        OriginalBigInt[2] := 9223372036854775807L; // Max + value
        OriginalBigInt[3] := -9223372036854775807L; // Max - value
        OriginalBigInt[4] := 16383; // 2b
        OriginalBigInt[5] := -98765432100L;
        OriginalBigInt[6] := 1L;
        for i := 7 to 100000 do begin
            if Random(2) = 1 then
                OriginalBigInt[i] := -Random(2147483647) // 0 to -4294967294
            else
                OriginalBigInt[i] := Random(2147483647); // 0 to 4611686014132420609
            if Random(2) = 1 then
                OriginalBigInt[i] *= abs(OriginalBigInt[i]);
        end;

        // Write all BigIntegers
        for i := 1 to 100000 do
            zigzag.WriteBigInt(outstream, OriginalBigInt[i]);

        tempblob.CreateInStream(instream);

        // Read all BigIntegers
        for i := 1 to 100000 do
            zigzag.ReadBigInt(instream, ReadBigInt[i]);

        EndTime := CurrentDateTime();
        Duration := EndTime - StartTime;

        CountDiff := 0;
        for i := 1 to 100000 do
            if OriginalBigInt[i] <> ReadBigInt[i] then
                CountDiff += 1;

        Message('Batch test BIGTEGER completed. \ Duration: %1 ms. \ Number of differences detected: %2 \ Original size: %3 \ Encoded size : %4', Duration div 1, CountDiff, 100000 * 8, instream.Length());

        // Generate 10000 random Decimals within +/- 214 746 217 216 353 with maximum scale 18
        clear(tempblob);

        OriginalDec[1] := 0;
        OriginalDec[2] := 999999999999.99;
        OriginalDec[3] := -999999999999.99;
        OriginalDec[4] := 3.1415926535897932384626433832;
        OriginalDec[5] := -3.1415926535897932384626433832;
        OriginalDec[6] := 1.2345;
        OriginalDec[7] := -1.2345;
        OriginalDec[8] := 123456789012345.67;
        OriginalDec[9] := -123456789012345.67;
        OriginalDec[10] := 0.000000000000000001; // smallest possible value

        for i := 11 to 100000 do begin
            // Limit integer part to 15 digits
            if Random(2) = 1 then
                IntegerPart := Random(2147483647)
            else begin
                IntegerPart := Random(2147483647); // up to Integer
                IntegerPart *= IntegerPart div 46566; // up to 99999999999999 (max mantissa supported by AL)
            end;
            if Random(2) = 1 then
                OriginalDec[i] := IntegerPart
            else begin
                Scale := 2 + Random(16); // 2..18 Scale, max supported AL scale is 18 (up to 28 in AL variable, but storing resulting in preicsion loss)
                OriginalDec[i] := IntegerPart / Power(10, Scale);
            end;
            if Random(2) = 1 then // negative
                OriginalDec[i] := -OriginalDec[i];
        end;

        StartTime := CurrentDateTime;

        tempblob.CreateOutStream(outstream);

        // Write all Decimals
        for i := 1 to 100000 do
            zigzag.WriteDecimal(outstream, OriginalDec[i]);

        tempblob.CreateInStream(instream);

        // Read all Decimals
        for i := 1 to 100000 do begin
            zigzag.ReadDecimal(instream, ReadDec[i]);
        end;

        EndTime := CurrentDateTime;
        Duration := EndTime - StartTime;

        // Compare and count differences
        CountDiff := 0;
        for i := 1 to 100000 do
            if OriginalDec[i] <> ReadDec[i] then
                Error(StrSubstNo('Difference read : %1 <> %2', OriginalDec[i], ReadDec[i]));
        //CountDiff += 1;

        Message('Batch test for Decimal completed. Duration: %1 ms. Number of differences detected: %2 \ Original size : %3 \ encoded size : %4', Duration div 1, CountDiff, 100000 * 12, instream.Length());

        // Generate 10000 random date
        clear(tempblob);

        OriginalDate[1] := 0D;
        OriginalDate[2] := Today;
        OriginalDate[3] := DMY2Date(12, 6, 2025);
        OriginalDate[4] := ClosingDate(DMY2Date(31, 12, 2005));
        OriginalDate[5] := DMY2Date(15, 2, 1995);
        OriginalDate[6] := DMY2Date(1, 1, 2050);
        OriginalDate[7] := DMY2Date(31, 12, 2005);
        OriginalDate[8] := DMY2Date(1, 1, 1753);

        for i := 9 to 100000 do
            OriginalDate[i] := DMY2Date(1 + Random(26), 1 + Random(11), Random(1000) + 1753);

        StartTime := CurrentDateTime;

        tempblob.CreateOutStream(outstream);

        // Write all dates
        for i := 1 to 100000 do
            zigzag.WriteDate(outstream, OriginalDate[i]);

        tempblob.CreateInStream(instream);

        // Read all dates
        for i := 1 to 100000 do
            zigzag.ReadDate(instream, ReadDate[i]);

        EndTime := CurrentDateTime;
        Duration := EndTime - StartTime;

        // Compare and count differences
        CountDiff := 0;
        for i := 1 to 100000 do
            if OriginalDate[i] <> ReadDate[i] then
                CountDiff += 1;
        //Error(StrSubstNo('Difference read : %1 <> %2', OriginalDate[i], ReadDate[i]));

        Message('Batch test for Date completed. Duration: %1 ms. Number of differences detected: %2 \ Original size : %3 \ encoded size : %4', Duration div 1, CountDiff, 10000 * 4, instream.Length());

        // Generate 10000 random time
        clear(tempblob);

        OriginalTime[1] := 120000T;
        OriginalTime[2] := 000000T;
        OriginalTime[3] := 235959T;
        OriginalTime[4] := 123456T;

        for i := 5 to 100000 do
            OriginalTime[i] := 000000T + Random(86400000);

        StartTime := CurrentDateTime;

        tempblob.CreateOutStream(outstream);

        // Write all Decimals
        for i := 1 to 100000 do
            zigzag.WriteTime(outstream, OriginalTime[i]);

        tempblob.CreateInStream(instream);

        // Read all Deci0mals
        for i := 1 to 100000 do
            zigzag.ReadTime(instream, ReadTime[i]);

        EndTime := CurrentDateTime;
        Duration := EndTime - StartTime;

        // Compare and count differences
        CountDiff := 0;
        for i := 1 to 100000 do
            if OriginalTime[i] <> ReadTime[i] then
                //Error(StrSubstNo('Difference read : %1 <> %2', OriginalDec[i], ReadDec[i]));
        CountDiff += 1;

        Message('Batch test for Time completed. Duration: %1 ms. Number of differences detected: %2 \ Original size : %3 \ encoded size : %4', Duration div 1, CountDiff, 10000 * 4, instream.Length());
    end;
    #endregion
}
