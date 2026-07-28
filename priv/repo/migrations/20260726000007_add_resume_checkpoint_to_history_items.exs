defmodule Playmark.Repo.Migrations.AddResumeCheckpointToHistoryItems do
  use Ecto.Migration

  def change do
    alter table(:history_items) do
      add(:resume_position_ms, :integer)
      add(:duration_ms, :integer)
    end
  end
end
