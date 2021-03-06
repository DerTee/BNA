using System;
using System.Reflection;
using System.Collections;
using System.Diagnostics;
using BNA.bindings;
using BNA.Math;

namespace BNA.Graphics
{
	[AttributeUsage(.Field, .ReflectAttribute)]
	public struct VertexUsageAttribute : Attribute
	{
		public VertexElementUsage usage;
		public int usageIndex;

		public this(VertexElementUsage usage, int usageIndex = 0)
		{
			this.usage = usage;
			this.usageIndex = usageIndex;
		}
	}

	public struct VertexBufferSpan
	{
		public readonly VertexBuffer Buffer;
		public readonly int StartIndex;
		public readonly int Length;

		public this(VertexBuffer buffer)
		{
			Buffer = buffer;
			StartIndex = 0;
			Length = buffer.VertexCount;
		}

		public this(VertexBuffer buffer, int index, int length)
		{
			Buffer = buffer;
			StartIndex = index;
			Length = length;
		}
	}

	public sealed class VertexBuffer : IDisposable
	{
		private static class VertexDeclarationCache<TVertex>
			where TVertex : struct
		{
			public static VertexDeclaration? Declaration;
			public static VertexElement[] Elements ~ delete _;

			// WORKAROUND: Beef compiler fails as of nightly 5/30/2020 with unresolved external with above implicit destructor if I don't have this explicit constructor here
			public static this()
			{
			}
		}

		public int VertexCount => _count;

		private FNA3D_DeviceHandle* _deviceHandle;
		private FNA3D_Buffer* _handle;

		private int _capacity;
		private int _count;
		private bool _dynamic;

		private Type _lastType;

		private FNAVertexBufferBinding _binding;
		private VertexDeclaration _vertexDeclaration;

		public this(GraphicsDevice graphicsDevice, bool dynamic = false)
		{
			_deviceHandle = graphicsDevice.[Friend]_deviceHandle;
			_handle = null;

			_dynamic = dynamic;
			_capacity = 0;
			_count = 0;

			_lastType = null;
			_vertexDeclaration.elements = null;
		}

		public ~this()
		{
			Dispose();
		}

		public void Dispose()
		{
			if(_handle != null)
			{
				FNA3D_binding.AddDisposeVertexBuffer(_deviceHandle, _handle);
			}

			_deviceHandle = null;
			_handle = null;
		}

		public void Set<TVertex>(TVertex[] vertices)
			where TVertex : struct
		{
			if(vertices.Count > _capacity || typeof(TVertex) != _lastType)
			{
				// we have to regenerate the vertex buffer in this case
				if(_handle != null)
				{
					FNA3D_binding.AddDisposeVertexBuffer(_deviceHandle, _handle);
				}

				_vertexDeclaration = GenVertexDeclaration<TVertex>();
				_handle = FNA3D_binding.GenVertexBuffer(_deviceHandle, _dynamic ? 1 : 0, .WriteOnly, (.)vertices.Count, sizeof(TVertex));

				_binding.vertexBuffer = _handle;
				_binding.vertexDeclaration = _vertexDeclaration;
				_binding.vertexOffset = 0;
				_binding.instanceFrequency = 0; //??

				_capacity = vertices.Count;
			}

			_count = vertices.Count;
			FNA3D_binding.SetVertexBufferData(_deviceHandle, _handle, 0, vertices.CArray(), (.)vertices.Count, sizeof(TVertex), sizeof(TVertex), .Discard);
		}

		public void Set<TVertex>(Span<TVertex> vertices)
			where TVertex : struct
		{
			if(vertices.Length > _capacity || typeof(TVertex) != _lastType)
			{
				// we have to regenerate the vertex buffer in this case
				if(_handle != null)
				{
					FNA3D_binding.AddDisposeVertexBuffer(_deviceHandle, _handle);
				}

				_vertexDeclaration = GenVertexDeclaration<TVertex>();
				_handle = FNA3D_binding.GenVertexBuffer(_deviceHandle, _dynamic ? 1 : 0, .WriteOnly, (.)vertices.Length, sizeof(TVertex));

				_binding.vertexBuffer = _handle;
				_binding.vertexDeclaration = _vertexDeclaration;
				_binding.vertexOffset = 0;
				_binding.instanceFrequency = 0; //??

				_capacity = vertices.Length;
			}

			_count = vertices.Length;
			FNA3D_binding.SetVertexBufferData(_deviceHandle, _handle, 0, vertices.Ptr, (.)vertices.Length, sizeof(TVertex), sizeof(TVertex), .Discard);
		}

		private VertexDeclaration GenVertexDeclaration<TVertex>()
			where TVertex : struct
		{
			// we've already got a declaration for this type cached, don't repeat unnecessary work
			if(VertexDeclarationCache<TVertex>.Declaration.HasValue)
			{
				return VertexDeclarationCache<TVertex>.Declaration.Value;
			}

			// sanity check struct size to make sure it's aligned on a 16-byte boundary
			if(sizeof(TVertex) % 16 != 0)
			{
				int remainder = 16 - ( sizeof(TVertex) % 16 );
				String typeName = scope String();
				typeof(TVertex).GetName(typeName);
				Debug.FatalError(scope String()..AppendF("Vertex type {0} does not align to a 16-byte boundary (consider adding {1} bytes of padding to the end)", typeName, remainder));
			}

			// we use reflection to enumerate fields of the struct and build a set of vertex elements out of them
			List<VertexElement> elements = scope List<VertexElement>();
			int32 curOffset = 0;

			for(var field in typeof(TVertex).GetFields())
			{
				// sanity check curOffset to make sure we don't cross a 16-byte boundary with a field. if we do, alert programmer that this struct will need padding

				int nextBoundary = ( ( curOffset / 16 ) * 16 ) + 16;
				int remaining = nextBoundary - curOffset;

				Debug.Assert(remaining >= field.FieldType.Size, scope String()..AppendF("Vertex type violates 16-byte boundary alignment at field {0} (consider adding at least {1} bytes of padding before it)",
					field.Name, remaining));

				VertexElement element = VertexElement();

				switch(field.FieldType)
				{
				case typeof(float):
					element.elementFormat = .Single;
					break;
				case typeof(Vec2):
					element.elementFormat = .Vector3;
					break;
				case typeof(Vec3):
					element.elementFormat = .Vector2;
					break;
				case typeof(Vec4):
					element.elementFormat = .Vector4;
					break;
				case typeof(Color):
					element.elementFormat = .Color;
					break;
				default:
					String tmp = scope String();
					field.FieldType.GetName(tmp);
					String tmp2 = scope String();
					typeof(TVertex).GetName(tmp2);
					Debug.FatalError(scope String()..AppendF("Unsupported vertex field type: {0} (in vertex struct {1})", tmp, tmp2));
					break;
				}

				// does field have a usage hint? if not, don't bind it (it's probably a padding field!)
				let result = field.GetCustomAttribute<VertexUsageAttribute>();
				if( result case .Ok(let usage))
				{
					element.elementUsage = usage.usage;
					element.usageIndex = (.)usage.usageIndex;
					element.offset = curOffset;
					elements.Add(element);
				}

				curOffset += field.FieldType.Size;
			}

			// copy to new array
			let elementArray = new VertexElement[elements.Count];
			elements.CopyTo(elementArray);

			VertexDeclaration declaration = VertexDeclaration();
			declaration.vertexStride = sizeof(TVertex);
			declaration.elements = elementArray.CArray();
			declaration.elementCount = (.)elementArray.Count;

			// cache the results
			VertexDeclarationCache<TVertex>.Declaration = declaration;
			VertexDeclarationCache<TVertex>.Elements = elementArray;
			return declaration;
		}
	}
}
