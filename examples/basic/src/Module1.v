Inductive my_bool : Type :=
| my_true
| my_false.

Definition my_negb (b : my_bool) : my_bool :=
  match b with
  | my_true => my_false
  | my_false => my_true
  end.
