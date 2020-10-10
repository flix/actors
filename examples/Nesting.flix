/// ///
/// /// An actor system that demonstrates how we can nest two actor systems. This is different from composition, where two nested actor systems can share actor names (one name maps to a different actor in each system), and nesting two systems just means we have two different systems, while composing two systems gives a single one.
/// ///
/// namespace Nesting {

///     ///
///     /// The main entry point of the actor system and its subsystems
///     ///
///     @test
///     pub def main(): Unit & Impure = {
///         let sys = ActorSystem.start(system(2));
///         let c = Channel.new();
///         <- Timer.milliseconds(200i64); // wait for initialization
///         // ping and wait an answer
///         if (???(sys, "nested", Msg("PING", c))) { // TODO: ActorSystem.send
///           <- c;
///           ()
///         } else {
///           ()
///         };
///         ActorSystem.shutdown(sys)
///     }

///     ///
///     /// Returns an actor system with one actor.
///     ///
///     /// The actor system uses empty policies.
///     ///
///     pub def system(n: Int): ActorSystem = {
///         let empty = ActorSystem.empty();
///         let actors = Map#{
///             "nested" -> nestedActor(n, None)
///         };
///         { actors = actors | empty }
///     }

///     ///
///     /// An actor that nests other actor systems
///     ///
///     pub def nestedActor(level: Int, s: Option[RunningActorSystem], dir: ActorDirectory, mailbox: Mailbox): ActorResult[Str] =
///         match <- mailbox {
///             case Start(c) =>
///                 if (level == 0) {
///                   // We got to the end of the nesting chain, just recurse
///                   c <- Ready;
///                   nestedActor(level, None, dir, mailbox)
///                 } else {
///                   // We need to nest more
///                   let sys = ActorSystem.start(system(level-1));
///                   c <- Ready;
///                   nestedActor(level, Some(sys), dir, mailbox)
///                 }
///             case Stop =>
///                 match s {
///                   // Shutdown children systems before shutting down ourselves
///                   case Some(sys) => ActorSystem.shutdown(sys)
///                   case None => ()
///                 };
///                 Done
///             case Msg("PING", c) =>
///                 // When we get a PING message, we either send it to the nested subsystem, or answer if we're the last subsystem
///                 match s {
///                   case Some(sys) => ???(sys, "nested", Msg("PING", c)); () // TODO: ActorSystem.send
///                   case None => c <- Msg("PONG", c); ()
///                 };
///                 nestedActor(level, s, dir, mailbox)
///             case Msg(msg, _) => ResumableCrash(nestedActor(level, s), "Unexpected message: " + msg)
///         }
/// }
