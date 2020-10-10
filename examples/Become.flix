/// ///
/// /// An actor system that demonstrates how an actor can change its behavior (i.e. "become" another actor).
/// ///
/// namespace Become {

///     ///
///     /// The main entry point of the actor system.
///     ///
///     @test
///     pub def main(): Unit & Impure  =
///         let sys = ActorSystem.start(system());
///         <- Timer.milliseconds(50i64);
///         ActorDirectory.send(sys, "greetingActor", Msg("HELO", Channel.new()));
///         ActorDirectory.send(sys, "greetingActor", Msg("HELO", Channel.new()));
///         ActorDirectory.send(sys, "greetingActor", Msg("HELO", Channel.new()));
///         ActorDirectory.send(sys, "greetingActor", Msg("HELO", Channel.new()));
///         ActorDirectory.send(sys, "greetingActor", Msg("HELO", Channel.new()));
///         ActorDirectory.send(sys, "greetingActor", Msg("HELO", Channel.new()));
///         <- Timer.milliseconds(50i64);
///         ActorSystem.shutdown(sys)

///     ///
///     /// Returns the actor system.
///     ///
///     pub def system(): ActorSystem = {
///         let empty = ActorSystem.empty();
///         let actors = Map#{
///             "greetingActor" -> danishGreetingActor(2)
///         };
///         { actors = actors | empty }
///     }

///     ///
///     /// An actor that prints a greeting in Danish.
///     ///
///     pub def danishGreetingActor(n: Int, dir: ActorDirectory, mailbox: Mailbox): ActorResult[Str] & Impure  =
///         match <- mailbox {
///             case Start(c)       => c <- Ready; danishGreetingActor(n, dir, mailbox)
///             case Stop           => Done
///             case Msg("HELO", _) => Console.printLine("Hejsa!");
///                                    if (n > 0)
///                                      danishGreetingActor(n - 1, dir, mailbox)
///                                    else
///                                      swedishGreetingActor(dir, mailbox)
///             case Msg(msg, _)    => ResumableCrash(danishGreetingActor(0), "Unexpected message: " + msg)
///         }

///     ///
///     /// An actor that prints a greeting in Swedish.
///     ///
///     pub def swedishGreetingActor(dir: ActorDirectory, mailbox: Mailbox): ActorResult[Str] & Impure  =
///         match <- mailbox {
///             case Start(c)       => c <- Ready; swedishGreetingActor(dir, mailbox)
///             case Stop           => Done
///             case Msg("HELO", _) => Console.printLine("Hej då!"); swedishGreetingActor(dir, mailbox)
///             case Msg(msg, _)    => ResumableCrash(swedishGreetingActor, "Unexpected message: " + msg)
///         }

/// }
