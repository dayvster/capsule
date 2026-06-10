pub const Error = error{
    SocketFailed,
    BindFailed,
    TimedOut,
    RecvFailed,
    InvalidUevent,
};
