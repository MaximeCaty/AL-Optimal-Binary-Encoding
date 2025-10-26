
# AL Optimal Binary Encoder

Offer data reading and writing in binary format with smaller length than built in AL stream function, in pure AL.

Numerical values are encoded using variable length similar as "ZigZag" algorithm with optimised behavous for undefined values and dates.

This can reduce the size of exported data, especially when dataset have small, undefined and zero values, **you can expect 20-40% reduction**.

You can use this along with built in AL read/write for other field type such as text.

## **Size comparaison**

	// This write 4 full bytes in the stream, using built in AL encoding of Integer
	OutStream.Write(Integer); 
	
	// This only write 1 byte when integer is in 0 or +/- 128
	// 2 bytes if +/- 16 684, ...
	OptimalBinCodeunit.WriteInt(Integer); 
	

| AL Datatype          | AL Fixed Bytes | Variable Bytes length encoding | Encoding                                                      |
| -------------------- | ------------ | ----------------------- | ---------------------------------------------------------------------- |
| Integer, Option      | 4            | 1 to 4                  | Signed ZigZag Encoding : 1 bytes 0 and +/- 128, 2 bytes : +/- 16 684, … |
| BigInteger, Duration | 8            | 2 to 8                  | Sign bit + Double ZigZag encoding :2 bytes : 0 and +/- 16 684,…         |
| Decimal              | 12           | 3 to 9                  | On Scale Byte + Sign bit and Double ZigZag encoding.                    |
| Date                 | 4            | 1 to 3                  | Undefined and "ClosingDate" flags + ZigZag encoding. 4th byte never used (outside 9999 years range)                           |
| Time                 | 4            | 1 to 4                  | Undefined flags + Signed ZigZag encoding                                |
| DateTime             | 8            | 2 to 7                  | Combine above Date and Time encoding                                    |
| Boolean              | 4            | 1                       | None, AL is just dumb and add 3 useless byte after the boolean          |


Why not other data type ? \
\
GUID : Due to the high entropy along the 16 bytes we can not save length using Zigzag here. We could split it into 4 integers but it would still have poor efficience. \
Text/Code : ASCII can not be reduced bellow 1 byte, and Outstream.Write(Text) already use UTF-8 variable length encoding (1 byte for ascii char, 2-3 bytes for non ascii char such as emoji). \
Other : less present in the application (such as DateFormula and RecordID) were not studied. \


## Usage


The codeunit must be initialized before you start using it.

If you set a custom base date, it must be the same option for writting and reading or you could get runtime error and incorrect read values.

	Initialize();
	// or 
	Initialize(BaseDate: Date)

Write in AL OutStream :

	WriteInt(var  OutStr: OutStream; Value: Integer)
	WriteBigInt(var  OutStr: OutStream; Value: BigInteger)
	WriteDecimal(var  OutStr: OutStream; Value: Decimal)
	WriteDate(var  OutStr: OutStream; Value: Date)
	WriteTime(var  OutStr: OutStream; Value: Time)
	WriteDateTime(var  OutStr: OutStream; Value: DateTime)
	WriteBool(var OutStr: OutStream; Value: Boolean)

Read AL InStream :

	ReadInt(var  InStr: InStream; var  Value: Integer)
	ReadBigInt(var  InStr: InStream; var  Value: BigInteger)
	ReadDecimal(var  InStr: InStream; var  Value: Decimal)
	ReadDate(var  InStr: InStream; var  Value: Date)
	ReadTime(var  InStr: InStream; var  Value: Time)
	ReadDateTime(var  InStr: InStream; var  Value: DateTime)
	ReadBool(var InStr: InStream; var Value: Boolean)
