pub const ParseError = error{
UnexpectedCharacter,
UnterminatedString,
InvalidNumber,
InvalidVariableName,
InvalidArrayIndex,
InvalidStatement,
UnknownOperator,
UnknownFunction,
ExtensionNotImplemented,
LineTooLong,
UnbalancedBrackets,
};

pub const RuntimeError = error{
ArrayNotSized,
IndexOutOfBounds,
DivisionByZero,
InvalidLabel,
InvalidLineNumber,
LabelNotFound,
LineOutOfRange,
StringIndexOutOfBounds,
TypeMismatch,
StackOverflow,
MemoryAllocationFailed,
};

pub const EllochkaError = ParseError || RuntimeError;