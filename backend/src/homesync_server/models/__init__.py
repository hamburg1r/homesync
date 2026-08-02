"""SQLAlchemy ORM models for the Homesync catalog."""

from __future__ import annotations

from sqlalchemy import ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class SchemaVersion(Base):
    __tablename__ = "schema_version"

    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    applied_at: Mapped[str] = mapped_column(Text, nullable=False)


class Device(Base):
    __tablename__ = "devices"

    device_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    kind: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[str] = mapped_column(Text, nullable=False)
    last_seen_at: Mapped[str | None] = mapped_column(Text, nullable=True)

    library_roots: Mapped[list[LibraryRoot]] = relationship(back_populates="device")


class LibraryRoot(Base):
    __tablename__ = "library_roots"

    root_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    device_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("devices.device_id"), nullable=False
    )
    abs_path: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    label: Mapped[str | None] = mapped_column(Text, nullable=True)
    enabled: Mapped[int] = mapped_column(Integer, nullable=False, default=1)

    device: Mapped[Device] = relationship(back_populates="library_roots")
    paths: Mapped[list[FilePath]] = relationship(back_populates="root")


class File(Base):
    __tablename__ = "files"

    file_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    content_hash: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    hash_algo: Mapped[str] = mapped_column(Text, nullable=False)
    mime_type: Mapped[str | None] = mapped_column(Text, nullable=True)
    size_bytes: Mapped[int] = mapped_column(Integer, nullable=False)
    title: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    taken_at: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str] = mapped_column(Text, nullable=False)
    updated_at: Mapped[str] = mapped_column(Text, nullable=False)
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)

    paths: Mapped[list[FilePath]] = relationship(back_populates="file")
    file_tags: Mapped[list[FileTag]] = relationship(back_populates="file")
    availability_rows: Mapped[list[Availability]] = relationship(
        back_populates="file"
    )


class FilePath(Base):
    __tablename__ = "file_paths"
    __table_args__ = (UniqueConstraint("root_id", "relative_path", name="ux_file_paths_root_rel"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    file_id: Mapped[str] = mapped_column(String(36), ForeignKey("files.file_id"), nullable=False)
    root_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("library_roots.root_id"), nullable=True
    )
    relative_path: Mapped[str] = mapped_column(Text, nullable=False)
    source_kind: Mapped[str] = mapped_column(Text, nullable=False, default="unknown")
    source_device_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("devices.device_id"), nullable=True
    )
    is_current: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    seen_at: Mapped[str] = mapped_column(Text, nullable=False)
    gone_at: Mapped[str | None] = mapped_column(Text, nullable=True)

    file: Mapped[File] = relationship(back_populates="paths")
    root: Mapped[LibraryRoot | None] = relationship(back_populates="paths")


class Tag(Base):
    __tablename__ = "tags"

    tag_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    color: Mapped[str | None] = mapped_column(Text, nullable=True)

    file_tags: Mapped[list[FileTag]] = relationship(back_populates="tag")


class FileTag(Base):
    __tablename__ = "file_tags"

    file_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("files.file_id"), primary_key=True
    )
    tag_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("tags.tag_id"), primary_key=True
    )

    file: Mapped[File] = relationship(back_populates="file_tags")
    tag: Mapped[Tag] = relationship(back_populates="file_tags")


class Availability(Base):
    __tablename__ = "availability"

    file_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("files.file_id"), primary_key=True
    )
    device_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("devices.device_id"), primary_key=True
    )
    mode: Mapped[str] = mapped_column(Text, nullable=False)
    updated_at: Mapped[str] = mapped_column(Text, nullable=False)

    file: Mapped[File] = relationship(back_populates="availability_rows")
