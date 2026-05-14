defmodule Rho.SchemaCoerceTest do
  use ExUnit.Case, async: true

  alias Rho.SchemaCoerce

  # ── String coercion ──────────────────────────────────────────────

  describe "coerce/3 :string" do
    test "passes through strings unchanged" do
      assert {:ok, "hello", []} = SchemaCoerce.coerce("hello", :string)
    end

    test "coerces integer to string" do
      assert {:ok, "42", [%{from: :number, to: :string}]} = SchemaCoerce.coerce(42, :string)
    end

    test "coerces float to string" do
      assert {:ok, "3.14", [%{from: :number, to: :string}]} = SchemaCoerce.coerce(3.14, :string)
    end

    test "coerces boolean to string" do
      assert {:ok, "true", [%{from: :boolean, to: :string}]} = SchemaCoerce.coerce(true, :string)

      assert {:ok, "false", [%{from: :boolean, to: :string}]} =
               SchemaCoerce.coerce(false, :string)
    end

    test "rejects nil in tool_call mode" do
      assert {:error, :nil_for_string} = SchemaCoerce.coerce(nil, :string)
    end

    test "coerces nil to empty string in extraction mode" do
      assert {:ok, "", [_]} = SchemaCoerce.coerce(nil, :string, mode: :extraction)
    end

    test "unwraps known wrapper keys" do
      assert {:ok, "text", _} = SchemaCoerce.coerce(%{"value" => "text"}, :string)
      assert {:ok, "text", _} = SchemaCoerce.coerce(%{"Value" => "text"}, :string)
      assert {:ok, "text", _} = SchemaCoerce.coerce(%{"text" => "text"}, :string)
      assert {:ok, "text", _} = SchemaCoerce.coerce(%{"Text" => "text"}, :string)
      assert {:ok, "text", _} = SchemaCoerce.coerce(%{"result" => "text"}, :string)
      assert {:ok, "text", _} = SchemaCoerce.coerce(%{"Result" => "text"}, :string)
    end

    test "rejects arbitrary single-field unwrap in tool_call mode" do
      assert {:error, {:cannot_coerce, :map, :string}} =
               SchemaCoerce.coerce(%{"x" => "text"}, :string)
    end

    test "does single-field unwrap in extraction mode" do
      assert {:ok, "text", _} = SchemaCoerce.coerce(%{"x" => "text"}, :string, mode: :extraction)
    end
  end

  # ── Integer coercion ─────────────────────────────────────────────

  describe "coerce/3 :integer" do
    test "passes through integers unchanged" do
      assert {:ok, 42, []} = SchemaCoerce.coerce(42, :integer)
    end

    test "coerces string to integer" do
      assert {:ok, 30, [%{from: :string, to: :integer}]} = SchemaCoerce.coerce("30", :integer)
    end

    test "coerces integral float to integer" do
      assert {:ok, 3, [%{from: :float, to: :integer}]} = SchemaCoerce.coerce(3.0, :integer)
    end

    test "rejects non-integral float" do
      assert {:error, {:non_integral_float, 3.5}} = SchemaCoerce.coerce(3.5, :integer)
    end

    test "coerces string float '3.0' to integer" do
      assert {:ok, 3, _} = SchemaCoerce.coerce("3.0", :integer)
    end

    test "rejects non-numeric string" do
      assert {:error, _} = SchemaCoerce.coerce("abc", :integer)
    end

    test "unwraps known wrapper keys" do
      assert {:ok, 42, _} = SchemaCoerce.coerce(%{"value" => 42}, :integer)
    end
  end

  # ── Pos integer coercion ─────────────────────────────────────────

  describe "coerce/3 :pos_integer" do
    test "passes through positive integers" do
      assert {:ok, 5, []} = SchemaCoerce.coerce(5, :pos_integer)
    end

    test "rejects zero" do
      assert {:error, {:not_positive, 0}} = SchemaCoerce.coerce(0, :pos_integer)
    end

    test "rejects negative" do
      assert {:error, {:not_positive, -1}} = SchemaCoerce.coerce(-1, :pos_integer)
    end

    test "coerces string to pos_integer" do
      assert {:ok, 5, _} = SchemaCoerce.coerce("5", :pos_integer)
    end
  end

  # ── Float coercion ───────────────────────────────────────────────

  describe "coerce/3 :float" do
    test "passes through floats unchanged" do
      assert {:ok, 3.14, []} = SchemaCoerce.coerce(3.14, :float)
    end

    test "coerces integer to float" do
      assert {:ok, 42.0, [%{from: :integer, to: :float}]} = SchemaCoerce.coerce(42, :float)
    end

    test "coerces string to float" do
      assert {:ok, 3.14, [%{from: :string, to: :float}]} = SchemaCoerce.coerce("3.14", :float)
    end

    test "coerces integer string to float" do
      assert {:ok, 42.0, [%{from: :string, to: :float}]} = SchemaCoerce.coerce("42", :float)
    end

    test "rejects non-numeric string" do
      assert {:error, _} = SchemaCoerce.coerce("abc", :float)
    end
  end

  # ── Number coercion ──────────────────────────────────────────────

  describe "coerce/3 :number" do
    test "passes through integers" do
      assert {:ok, 42, []} = SchemaCoerce.coerce(42, :number)
    end

    test "passes through floats" do
      assert {:ok, 3.14, []} = SchemaCoerce.coerce(3.14, :number)
    end

    test "coerces integer string" do
      assert {:ok, 42, [%{from: :string, to: :number}]} = SchemaCoerce.coerce("42", :number)
    end

    test "coerces float string" do
      assert {:ok, 3.14, [%{from: :string, to: :number}]} = SchemaCoerce.coerce("3.14", :number)
    end
  end

  # ── Boolean coercion ─────────────────────────────────────────────

  describe "coerce/3 :boolean" do
    test "passes through booleans unchanged" do
      assert {:ok, true, []} = SchemaCoerce.coerce(true, :boolean)
      assert {:ok, false, []} = SchemaCoerce.coerce(false, :boolean)
    end

    test "coerces truthy strings" do
      for s <- ~w(true yes 1 True YES) do
        assert {:ok, true, [_]} = SchemaCoerce.coerce(s, :boolean)
      end
    end

    test "coerces falsy strings" do
      for s <- ~w(false no 0 False NO) do
        assert {:ok, false, [_]} = SchemaCoerce.coerce(s, :boolean)
      end
    end

    test "coerces integer 1 to true, 0 to false" do
      assert {:ok, true, [%{from: :integer, to: :boolean}]} = SchemaCoerce.coerce(1, :boolean)
      assert {:ok, false, [%{from: :integer, to: :boolean}]} = SchemaCoerce.coerce(0, :boolean)
    end

    test "rejects ambiguous strings" do
      assert {:error, _} = SchemaCoerce.coerce("maybe", :boolean)
    end
  end

  # ── {:in, variants} coercion ─────────────────────────────────────

  describe "coerce/3 {:in, variants}" do
    test "exact match returns variant unchanged" do
      assert {:ok, "January", []} = SchemaCoerce.coerce("January", {:in, ~w(January February)})
    end

    test "case-insensitive match" do
      assert {:ok, "January", [%{from: :case_mismatch, to: :in}]} =
               SchemaCoerce.coerce("january", {:in, ~w(January February)})
    end

    test "works with atom variants" do
      assert {:ok, :active, []} = SchemaCoerce.coerce("active", {:in, [:active, :inactive]})
    end

    test "case-insensitive with atom variants" do
      assert {:ok, :Active, [%{from: :case_mismatch}]} =
               SchemaCoerce.coerce("active", {:in, [:Active, :Inactive]})
    end

    test "rejects unknown variant" do
      assert {:error, {:not_a_variant, "March", _}} =
               SchemaCoerce.coerce("March", {:in, ~w(January February)})
    end

    test "coerces number to variant string" do
      assert {:ok, "1", []} = SchemaCoerce.coerce(1, {:in, ~w(1 2 3)})
    end
  end

  # ── {:list, inner} coercion ──────────────────────────────────────

  describe "coerce/3 {:list, inner}" do
    test "coerces list items recursively" do
      assert {:ok, [1, 2, 3], repairs} = SchemaCoerce.coerce(["1", "2", "3"], {:list, :integer})
      assert match?([_, _, _], repairs)
    end

    test "scalar-to-list wrap" do
      assert {:ok, ["hello"], [%{from: :scalar, to: :list}]} =
               SchemaCoerce.coerce("hello", {:list, :string})
    end

    test "scalar-to-list with inner coercion" do
      assert {:ok, [42], repairs} = SchemaCoerce.coerce("42", {:list, :integer})
      assert match?([_, _], repairs)
    end

    test "passes through correctly typed list" do
      assert {:ok, [1, 2, 3], []} = SchemaCoerce.coerce([1, 2, 3], {:list, :integer})
    end

    test "rejects list item that cannot be coerced" do
      assert {:error, {:list_item_coerce_failed, _}} =
               SchemaCoerce.coerce(["abc"], {:list, :integer})
    end
  end

  # ── :map coercion ────────────────────────────────────────────────

  describe "coerce/3 :map" do
    test "passes through maps unchanged" do
      assert {:ok, %{"a" => 1}, []} = SchemaCoerce.coerce(%{"a" => 1}, :map)
    end

    test "rejects non-maps" do
      assert {:error, _} = SchemaCoerce.coerce("not a map", :map)
    end
  end

  # ── coerce_fields/3 ─────────────────────────────────────────────

  describe "coerce_fields/3" do
    test "coerces multiple fields according to schema" do
      schema = [name: [type: :string], count: [type: :integer]]
      args = %{name: "foo", count: "5"}

      assert {:ok, %{name: "foo", count: 5}, repairs} = SchemaCoerce.coerce_fields(args, schema)
      assert match?([_], repairs)
      assert hd(repairs).field == :count
    end

    test "passes through correctly typed fields with no repairs" do
      schema = [name: [type: :string], count: [type: :integer]]
      args = %{name: "foo", count: 5}

      assert {:ok, ^args, []} = SchemaCoerce.coerce_fields(args, schema)
    end

    test "returns error for missing required field" do
      schema = [name: [type: :string, required: true]]
      args = %{}

      assert {:error, {:missing_required, :name}} = SchemaCoerce.coerce_fields(args, schema)
    end

    test "allows missing optional field" do
      schema = [name: [type: :string], optional: [type: :string]]
      args = %{name: "foo"}

      assert {:ok, %{name: "foo"}, []} = SchemaCoerce.coerce_fields(args, schema)
    end

    test "returns error when coercion fails" do
      schema = [count: [type: :integer]]
      args = %{count: "not_a_number"}

      assert {:error, {:coerce_failed, :count, _}} = SchemaCoerce.coerce_fields(args, schema)
    end

    test "preserves extra keys not in schema" do
      schema = [name: [type: :string]]
      args = %{name: "foo", extra: "bar"}

      assert {:ok, %{name: "foo", extra: "bar"}, []} = SchemaCoerce.coerce_fields(args, schema)
    end

    test "tags repairs with field name" do
      schema = [a: [type: :integer], b: [type: :boolean]]
      args = %{a: "1", b: "true"}

      assert {:ok, %{a: 1, b: true}, repairs} = SchemaCoerce.coerce_fields(args, schema)
      assert Enum.any?(repairs, &(&1.field == :a))
      assert Enum.any?(repairs, &(&1.field == :b))
    end
  end

  # ── Property: no false positives ─────────────────────────────────

  describe "property: identity for correctly typed values" do
    test "string passthrough" do
      for s <- ["", "hello", "with spaces", "123", "true"] do
        assert {:ok, ^s, []} = SchemaCoerce.coerce(s, :string)
      end
    end

    test "integer passthrough" do
      for i <- [-1, 0, 1, 42, 1_000_000] do
        assert {:ok, ^i, []} = SchemaCoerce.coerce(i, :integer)
      end
    end

    test "float passthrough" do
      for f <- [-1.5, 0.0, 1.0, 3.14, 100.001] do
        assert {:ok, ^f, []} = SchemaCoerce.coerce(f, :float)
      end
    end

    test "boolean passthrough" do
      assert {:ok, true, []} = SchemaCoerce.coerce(true, :boolean)
      assert {:ok, false, []} = SchemaCoerce.coerce(false, :boolean)
    end

    test "list passthrough" do
      assert {:ok, [1, 2, 3], []} = SchemaCoerce.coerce([1, 2, 3], {:list, :integer})
      assert {:ok, ["a", "b"], []} = SchemaCoerce.coerce(["a", "b"], {:list, :string})
    end

    test "map passthrough" do
      m = %{"key" => "val"}
      assert {:ok, ^m, []} = SchemaCoerce.coerce(m, :map)
    end
  end

  # ── Unknown types pass through ───────────────────────────────────

  describe "unknown types" do
    test "passes through value for unrecognized type spec" do
      assert {:ok, "anything", []} = SchemaCoerce.coerce("anything", :custom_type)
    end
  end
end
